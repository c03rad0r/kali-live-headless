#!/usr/bin/env bash
# build.sh — build the customized Kali Live ISO (headless Wi-Fi + SSH).
#
# How it works (all supported upstream customization points, no patches to
# Kali's scripts):
#   1. Clone the official kali-live build scripts at a pinned revision.
#   2. Overlay this repo's kali-config/common additions into it:
#        - package-lists/headless.list.chroot      (extra packages)
#        - includes.chroot/...                     (sshd drop-in, systemd
#                                                   units, /usr/local/sbin
#                                                   runtime scripts)
#        - hooks/live/zz-headless-configure.hook.chroot
#   3. Stage generated secrets (NetworkManager profile with the Wi-Fi PSK,
#      authorized_keys, hostname, regdom defaults) into the same tree.
#   4. Run upstream ./build.sh (host) or ./build-in-container.sh (Docker).
#   5. Archive the ISO into output/iso-build<N>/ (checksums + provenance,
#      see BUILDS.md) and point the output/kali-*.iso slot symlink at it.
#
# Two build ways, and which one to use:
#   ./build.sh                 full pipeline (debootstrap + every package).
#                              Required for release builds, pin bumps and any
#                              package-list change. ~3h.
#   tools/iso-hotpatch.sh      repack an existing ISO's squashfs with new
#                              overlay files (scripts/units/config), no apt, no
#                              debootstrap. ~30 min. Only for overlay-only
#                              changes — never for package changes.
#
# There is no "cached chroot" build: upstream's build.sh calls
# cleanup_fs force at stage [1/4] and wipes chroot/, cache/ and config/
# unconditionally, so `-k/--keep` only preserves artifacts *after* a build
# (still useful for debugging a failure, see --keep-artifacts).
#
# Secrets are staged only for the duration of the build and scrubbed
# afterwards (disable with --keep-secrets). ./config keeps the only other
# copy (chmod 600, git-ignored).
#
# The build runs under a lock (one build per output dir) and the ISO is
# written to a staging dir first, so a failed build can never destroy the
# previous archive (build #9 was lost that way).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO_DIR"

# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/config}"
BUILD_DIR="$REPO_DIR/build"
UPSTREAM_DIR="$BUILD_DIR/kali-live"
OVERLAY_DIR="$REPO_DIR/overlay/kali-config/common"

KEEP_SECRETS=false
FORCE_RECLONE=false
DRY_RUN=false
KEEP_ARTIFACTS=false
POOL_DIR=""
ARCHIVE=true
SQUASHFS_COMP="zstd"
OPT_OUT="" OPT_VARIANT="" OPT_ARCH="" OPT_BRANCH="" OPT_REF="" OPT_NUMBER="" OPT_SDE=""

usage() {
  cat <<EOF
Usage: ./build.sh [OPTIONS]

Options:
  -o, --output DIR     Output directory (default: ./output)
  -v, --variant V      Kali live variant (default: from config, 'default')
  -a, --arch A         Architecture (default: amd64)
  -b, --branch B       Kali branch (default: kali-rolling)
  -R, --ref REF        Pin upstream kali-live git ref (commit or branch)
      --sde EPOCH      Pin SOURCE_DATE_EPOCH explicitly. A build is identified
                       by (commit, sde): re-running the same pair is a
                       *reproduction check*, not a new artifact — build.sh
                       compares the sha512 against the archived one and says
                       REPRODUCED or MISMATCH. Default: HEAD's commit time
      --keep-artifacts Keep the chroot/binary tree after the build (upstream
                       -k) — for debugging a failed run, not for speed
      --pool           Freeze this build's .deb set into the content-addressed
                       pool (tools/deb-pool.sh) so a later build can be
                       reproduced offline. Implies --keep-artifacts. Pool
                       location: $KLH_DEB_POOL or
                       ~/.local/share/kali-live-headless/deb-pool
      --number N       Archive this build as output/iso-buildN/
                       (default: next free number)
      --no-archive     Leave the ISO in the output dir, do not archive it
      --keep-secrets   Keep staged secrets in build/ after the build
      --force-reclone  Discard and re-clone the upstream tree
      --dry-run        Stage and validate only, do not build
  -h, --help           This help

Examples:
  ./build.sh                        # full build (release; ~3h)
  BASE=debian ./build.sh            # same stack on a Debian trixie base
  tools/iso-hotpatch.sh --build 11  # overlay-only repack (~30 min)
  ./test.sh --level static  # 17s: syntax/config/units, no ISO, no VM

Environment:
  BASE=kali|debian   Distro base for the image (default kali — the
                     historical flow, byte-identical). debian = trixie with
                     the same headless stack; see lib/distro/.
EOF
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)       OPT_OUT=${2:?}; shift 2 ;;
    -v|--variant)      OPT_VARIANT=${2:?}; shift 2 ;;
    -a|--arch)         OPT_ARCH=${2:?}; shift 2 ;;
    -b|--branch)       OPT_BRANCH=${2:?}; shift 2 ;;
    -R|--ref)          OPT_REF=${2:?}; shift 2 ;;
    --keep-artifacts)  KEEP_ARTIFACTS=true; shift ;;
    --pool)            POOL_DIR="${KLH_DEB_POOL:-$HOME/.local/share/kali-live-headless/deb-pool}"
                       KEEP_ARTIFACTS=true; shift ;;
    --zstd)            SQUASHFS_COMP=zstd; shift ;;
    --xz)              SQUASHFS_COMP=xz; shift ;;
    --sde)             OPT_SDE=${2:?}; shift 2 ;;
    --number)          OPT_NUMBER=${2:?}; shift 2 ;;
    --no-archive)      ARCHIVE=false; shift ;;
    --keep-secrets)    KEEP_SECRETS=true; shift ;;
    --force-reclone)   FORCE_RECLONE=true; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    -h|--help)         usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

klh_load_config "$CONFIG_FILE"
klh_check_config_perms "$CONFIG_FILE"

# ------------------------------------------------------------- distro base
# BASE (env or ./config; default kali) selects the distro adapter that owns
# every base-specific delta: suite string, mirrors, keyring, firmware
# policy, package-list mapping, ISO identity. kali's adapter is all no-ops —
# the pre-spike behavior, exactly.
BASE="${BASE:-kali}"
klh_load_distro "$BASE"

[ -n "$OPT_OUT" ]     && OUT_DIR="$OPT_OUT"
[ -n "$OPT_VARIANT" ] && VARIANT="$OPT_VARIANT"
[ -n "$OPT_ARCH" ]    && ARCH="$OPT_ARCH"
[ -n "$OPT_BRANCH" ]  && BRANCH="$OPT_BRANCH"
[ -n "$OPT_REF" ]     && KALI_LIVE_REF="$OPT_REF"

# BRANCH: klh_load_config defaulted it to its historical value before the
# adapter existed. If the ADAPTER declares it pins unset branches and the
# operator gave no explicit branch (no -b, no BRANCH= in ./config),
# substitute the adapter's default suite; explicit values go through the
# adapter's validator below either way.
if [ "${KLH_DISTRO_PIN_BRANCH_WHEN_UNSET:-false}" = true ] && [ -z "$OPT_BRANCH" ] \
   && [ "$BRANCH" = "kali-rolling" ] \
   && ! grep -qE '^[[:space:]]*BRANCH=' "$CONFIG_FILE" 2>/dev/null; then
  BRANCH="$KLH_DISTRO_DEFAULT_BRANCH"
  klh_info "BASE=$KLH_BASE: branch defaulted to $BRANCH (set BRANCH in ./config or pass -b to pin)"
fi
klh_distro_validate_branch "$BRANCH"

# BUILD_MIRROR: if the ADAPTER declares it needs an explicit mirror and
# none is configured, inject the adapter's default (upstream's hardcoded
# default is a kali URL — wrong for every other base). Adapters that don't
# declare it keep the exact historical no--m flow.
if [ "${KLH_DISTRO_NEEDS_EXPLICIT_MIRROR:-false}" = true ] && [ -z "${BUILD_MIRROR:-}" ]; then
  BUILD_MIRROR="${KLH_DISTRO_DEFAULT_MIRROR:?adapter property error}"
  klh_info "BASE=$KLH_BASE: build mirror defaulted to $BUILD_MIRROR"
fi

OUT_DIR="${OUT_DIR:-$REPO_DIR/output}"
mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")

# ------------------------------------------------------- one build at a time
# Two concurrent runs share build/kali-live (the chroot) and silently produce
# garbage; killed drivers used to leave orphaned clients spinning for days
# (2026-10-22, ~1.3 CPU-days). A lock makes overlap impossible.
klh_require_cmd flock
LOCK_FILE="$OUT_DIR/.build.lock"
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
  klh_die "another build already holds $LOCK_FILE ($(cat "$LOCK_FILE" 2>/dev/null || echo 'no holder info')) — wait for it, or delete the lock file if it is stale"
fi
printf 'pid=%s started=%s\n' "$$" "$(date -Is)" > "$LOCK_FILE"

next_build_number() {
  local last
  last=$(find "$OUT_DIR" -maxdepth 1 -type d -name 'iso-build*' 2>/dev/null \
    | sed 's/.*iso-build//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
  echo $(( ${last:-0} + 1 ))
}
BUILD_NUM=${OPT_NUMBER:-$(next_build_number)}
STAGE_OUT="$OUT_DIR/.stage-$BUILD_NUM"

SSH_PUBKEY_PATH=$(klh_expand_tilde "$SSH_PUBKEY_PATH")
[ -f "$SSH_PUBKEY_PATH" ] || klh_die "SSH public key not found: $SSH_PUBKEY_PATH (re-run ./configure.sh)"

# ------------------------------------------------------------- environment
klh_require_cmd git
free_space_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
AVAIL=$(free_space_gb "$REPO_DIR")
# 30G is the release-build rule (the archive keeps ISO + tree side by side).
# A RAM build runs in a tmpfs sized for exactly one tree and the ISO, so it
# sets KLH_MIN_FREE_G lower — otherwise the guard rejects a 14G ramdisk that
# is, by construction, big enough.
MIN_FREE_G="${KLH_MIN_FREE_G:-30}"
[ "$AVAIL" -ge "$MIN_FREE_G" ] || klh_die "only ${AVAIL}G free under $REPO_DIR — a Kali live build needs ~${MIN_FREE_G}G (chroot + ISO + caches; KLH_MIN_FREE_G overrides)"

# distro adapter owns the mirror probe (kali: http.kali.org as always;
# debian: deb.debian.org) — see lib/distro/.
klh_distro_check_reachability

# ------------------------------------------------------- upstream checkout
if [ "$FORCE_RECLONE" = true ] && [ -d "$UPSTREAM_DIR" ]; then
  klh_info "removing existing upstream tree (--force-reclone)"
  rm -rf "$UPSTREAM_DIR"
fi
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  klh_info "cloning upstream kali-live ($KLH_UPSTREAM_URL)"
  mkdir -p "$BUILD_DIR"
  git clone --depth 200 "$KLH_UPSTREAM_URL" "$UPSTREAM_DIR"
fi
git -C "$UPSTREAM_DIR" fetch --depth 200 origin >/dev/null 2>&1 || klh_warn "git fetch failed — using local copy"
if ! git -C "$UPSTREAM_DIR" checkout --detach "$KALI_LIVE_REF" 2>/dev/null; then
  klh_warn "ref $KALI_LIVE_REF not found locally; fetching it explicitly"
  git -C "$UPSTREAM_DIR" fetch --depth 200 origin "$KALI_LIVE_REF"
  git -C "$UPSTREAM_DIR" checkout --detach "$KALI_LIVE_REF"
fi
if [ -n "$(git -C "$UPSTREAM_DIR" status --porcelain)" ]; then
  klh_warn "upstream tree dirty — resetting (stale staged files from a previous run?)"
  git -C "$UPSTREAM_DIR" reset --hard >/dev/null
  git -C "$UPSTREAM_DIR" clean -qfd
fi
UPSTREAM_SHA=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
klh_ok "upstream kali-live at $UPSTREAM_SHA (ref $KALI_LIVE_REF)"

# Base-specific repointing of the pristine upstream tree (debian: keyring,
# mirrors, suite gate, ISO identity; kali: no-op). Must run while the tree
# is freshly reset — every edit self-verifies against the pin.
klh_distro_prepare_upstream

# ----------------------------------------------------- overlay + staging
KLH_COMMON="$UPSTREAM_DIR/kali-config/common"
mkdir -p "$KLH_COMMON"

# (the dead staging-time apt-cache symlink block was removed in main; the
#  reason is recorded in docs/reproducible-builds.md — do not re-add a cache
#  that expects live-build to populate cache/packages.chroot)

klh_info "overlaying repo customizations into kali-config/common/"
cp -a "$OVERLAY_DIR/." "$KLH_COMMON/"

# The deb-pool hook copies ~900MB of .deb files inside the chroot, so it is
# staged only for pooled builds. The rootfs/excludes entry that keeps that copy
# out of the squashfs is always staged (a no-op path when pooling is off).
if [ -z "$POOL_DIR" ]; then
  rm -f "$KLH_COMMON/hooks/live/zzz-klh-deb-pool.hook.chroot"
fi

# PROVENANCE GUARD — no mystery files. Everything just staged must be a
# git-tracked overlay file. Build #18 shipped a libvirtd drop-in from an
# UNCOMMITTED overlay file that was deleted from the worktree after the
# cut: a provenance black hole whose dangling Requires= wedged every
# boot on hardware (libvirtd could never socket-activate). Run BEFORE
# any generated files land in the staged tree.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # allowed = upstream-native (the pinned clone ships its own
  # kali-config files we do not overlay — first live run flagged
  # upstream's grub.cfg as "mystery") UNION our git-tracked overlay
  mystery=$(cd "$KLH_COMMON" && find . -type f | sort > /tmp/klh-staged.$$
    { git -C "$REPO_DIR" ls-files "overlay/kali-config/common" | sed 's|^overlay/kali-config/common/|./|'
      git -C "$UPSTREAM_DIR" ls-files "kali-config/common" 2>/dev/null | sed 's|^kali-config/common/|./|'
      # build-time downloads (verified by sha/version at download): the
      # pinned cloudflared binary and the fips .deb — neither is in git,
      # both land in the persistent staged tree and survive cp -a
      echo './includes.chroot/usr/local/bin/cloudflared'
      ls ./packages.chroot/*.deb 2>/dev/null || true; } | sort -u > /tmp/klh-git.$$
    comm -23 /tmp/klh-staged.$$ /tmp/klh-git.$$
    rm -f /tmp/klh-staged.$$ /tmp/klh-git.$$)
  if [ -n "$mystery" ]; then
    klh_die "staged files with NO git source (uncommitted overlay leftovers?): $mystery"
  fi
  klh_ok "overlay provenance: every staged file is git-tracked"
fi

# KVM stack: package list written only for WITH_KVM builds; the unit
# files/scripts from the overlay are removed otherwise so nothing dead
# ships in the ISO.
# LEAN profile: strips DEFAULT-KALI weight (the ~1GB firmware whale,
# the kali-linux-core tools baseline, the desktop) while KEEPING the
# project's own stack — KVM/vmstore ride WITH_KVM, mesh/rescue ride
# their own knobs, on any variant.
if [ "$WITH_KVM" = true ]; then
  cat > "$KLH_COMMON/package-lists/kvm.list.chroot" <<'EOF'
## KVM/libvirt stack (WITH_KVM=true builds) — see README "KVM"
qemu-system-x86
libvirt-daemon-system
libvirt-clients
virt-install
virt-manager
dnsmasq-base
## NTFS VM store (docs/vm-store-ntfs-research.md): the only RW-capable NTFS
## driver on the live kernel (ntfs3 module is absent; ntfs-3g would already
## be pulled in transitively, but metapackage contents churn — pin it).
ntfs-3g
EOF
  klh_info "KVM stack baked in (libvirtd enabled at boot; guests NAT-only, host shielded on virbr0; opt-in NTFS vm store available)"
else
  rm -f "$KLH_COMMON/package-lists/kvm.list.chroot"
  rm -f "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-kvm-enable.service" \
        "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-kvm-firewall.service" \
        "$KLH_COMMON/includes.chroot/etc/systemd/system/kali-live-vmstore-mount.service" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-kvm-enable" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-kvm-firewall" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-vmstore-mount" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-vm-create" \
        "$KLH_COMMON/includes.chroot/usr/local/sbin/kali-live-vm-rm" \
        "$KLH_COMMON/includes.chroot/etc/modprobe.d/klh-kvm-nested.conf"
  klh_info "KVM stack omitted (WITH_KVM=false)"
fi

# LEAN file staging (after the WITH_KVM gate so its removals have run)
if [ "$LEAN" = true ]; then
    cat > "$KLH_COMMON/package-lists/hardware-support.list.chroot" <<'LEOF'
## LEAN: only firmware a headless wifi stick plausibly needs — the full
## kali-linux-firmware collection is ~1GB of vendor blobs this profile
## refuses to carry. Add your adapter's blob here if missing.
firmware-linux-free
firmware-iwlwifi
firmware-realtek
firmware-atheros
firmware-ath9k-htc
firmware-misc-nonfree
LEOF
    rm -f "$KLH_COMMON/package-lists/headless.list.chroot"
    klh_ok "LEAN profile staged: slim firmware, no KVM, headless-lean package list"
fi

# Base-specific package lists (debian: SELECTIVE firmware policy + stripping
# kali-only package names; kali: no-op). Runs AFTER LEAN so a BASE=debian
# LEAN build also gets the disciplined list. All writes happen post-guard:
# generated files, not overlay provenance.
klh_distro_stage_package_lists "$KLH_COMMON"


# Default boot entry: move syslinux's "menu default" onto the chosen
# entry and point GRUB at its index. Upstream defaults to the first
# "Live system" entry; BOOT_DEFAULT=forensic makes the forensic entry
# (no swap, no automount of internal disks) the zero-interaction default.
LIVE_CFG="$KLH_COMMON/bootloaders/syslinux_common/live.cfg.in"
GRUB_CFG="$KLH_COMMON/bootloaders/grub-pc/config.cfg"
if [ -f "$LIVE_CFG" ]; then
  sed -i '/^[[:space:]]*menu default[[:space:]]*$/d' "$LIVE_CFG"
  if [ "$BOOT_DEFAULT" = forensic ]; then
    sed -i '/menu label Live system (@FLAVOUR@ ^forensic mode)/a\        menu default' "$LIVE_CFG"
  else
    sed -i '/menu label \^Live system (@FLAVOUR@)/a\        menu default' "$LIVE_CFG"
  fi
fi
[ -f "$GRUB_CFG" ] && sed -i "s/^set default=.*/set default=$([ "$BOOT_DEFAULT" = forensic ] && echo 1 || echo 0)/" "$GRUB_CFG"
klh_info "default boot entry: $BOOT_DEFAULT (auto-boots after 5s)"

# zstd squashfs: NOW THE DEFAULT (BIOS-boot-gated 2026-10-25, build #40:
# 263/0, +3.3% size, ~15min compression vs ~30-55min xz — the full
# evidence in docs/zstd-squashfs-experiment-notes.md). --xz opts back to
# the old compressor for comparison or forensics.
if [ "$SQUASHFS_COMP" = xz ]; then
    export KLH_SQUASHFS_COMP=xz
    klh_info "SQUASHFS: xz (explicit --xz)"
else
    if ! grep -q 'chroot-squashfs-compression-type' "$UPSTREAM_DIR/auto/config" 2>/dev/null; then
        sed -i 's/^  --bootappend-live /  --chroot-squashfs-compression-type zstd \\\n  --bootappend-live /' "$UPSTREAM_DIR/auto/config"
    fi
    grep -q 'chroot-squashfs-compression-type zstd' "$UPSTREAM_DIR/auto/config" 2>/dev/null \
        || klh_die "failed to inject zstd compression into auto/config (sed pattern drifted?)"
    export KLH_SQUASHFS_COMP=zstd
    klh_info "SQUASHFS: zstd (default; boot-gated #40)"
fi

# FR-6 (2026-10-26): toram by DEFAULT, conditionally. The default entry
# gains `toram=filesystem.squashfs` (squashfs-only copy, ~2.2G); our patched
# 9990-toram-todisk.sh refuses the copy below 4G headroom (KVM guests) and
# the boot falls through to the medium — archiso's copytoram=auto pattern.
# Explicit entries survive for both directions; toram-force skips headroom.
if [ "$TORAM_DEFAULT" = true ] && [ -f "$LIVE_CFG" ]; then
    if ! grep -q "toram=filesystem" "$LIVE_CFG"; then
        # the FIRST entry (label live-@FLAVOUR@) is the default: append the
        # toram module to its append line only
        sed -i '/^label live-@FLAVOUR@$/,/append/ s|^        append @APPEND_LIVE@|        append @APPEND_LIVE@ toram=filesystem.squashfs|' "$LIVE_CFG"
        klh_info "boot menu: default entry now toram=filesystem.squashfs (auto; falls back to medium below 4G headroom)"
    fi
fi

# Optional "Live (load to RAM)" entry: live-boot's toram copies the whole
# squashfs into RAM up front (sequential read, fast) and then runs purely
# from memory — vs the default overlay where every first read page-faults
# off the USB stick. With the minimal variant the upfront copy is small
# enough that this is usually a pure win; pick it from the boot menu.
if [ "$TORAM_ENTRY" = true ]; then
    if [ -f "$LIVE_CFG" ] && ! grep -q "load to" "$LIVE_CFG"; then
        sed -i '/^label live-@FLAVOUR@-failsafe/i\
label live-toram-@FLAVOUR@\
        menu label Live system (@FLAVOUR@ - load to ^RAM)\
        linux @LINUX@\
        initrd @INITRD@\
        append @APPEND_LIVE@ toram=filesystem.squashfs toram-force\
' "$LIVE_CFG"
    fi
    # grub's MENU lives in grub.cfg (config.cfg only holds settings)
    GRUB_MENU="$KLH_COMMON/bootloaders/grub-pc/grub.cfg"
    if [ -f "$GRUB_MENU" ] && ! grep -q "load to RAM" "$GRUB_MENU"; then
        sed -i '/forensic mode)"/i\
menuentry "Live system (@FLAVOUR_LIVE@ - load to RAM)" {\
        linux @KERNEL_LIVE@ @APPEND_LIVE@ toram=filesystem.squashfs toram-force\
        initrd @INITRD_LIVE@\
}\
' "$GRUB_MENU"
    fi
    klh_info "boot menu: 'Live (load to RAM)' entry added (toram)"
fi

# Scrub staged secrets on ANY exit from here on. The trap must be armed
# BEFORE the secrets are staged (review M2: staging first, trapping later
# left the PSK profile on disk when an early command failed).
scrub_secrets() {
  if [ -n "${NM_PROFILE:-}" ]; then rm -f "$NM_PROFILE"; fi
  # authorized_keys/hostname/regdom are not secret, but remove for cleanliness
  if [ -n "${STAGE_ETC:-}" ]; then rm -rf "$STAGE_ETC"; fi
  rm -rf "$KLH_COMMON/includes.chroot/etc/default/kali-live-headless"
}
[ "$KEEP_SECRETS" = true ] || trap scrub_secrets EXIT

# 1) NetworkManager profile (contains the PSK — mode 0600, never in git).
#    Rendered by the shared generator (also used at boot for the KLHCONFIG
#    override) so build-time and boot-time substitution stay identical.
GEN="$OVERLAY_DIR/includes.chroot/usr/local/sbin/kali-live-headless-wifi-gen"
[ -x "$GEN" ] || klh_die "profile generator missing: $GEN"
NM_DIR="$KLH_COMMON/includes.chroot/etc/NetworkManager/system-connections"
mkdir -p "$NM_DIR"
klh_info "generating NetworkManager profile (secret — not printed)"
NM_PROFILE="$NM_DIR/headless-wifi.nmconnection"
KLH_SSID="$WIFI_SSID" KLH_PSK="$WIFI_PSK" KLH_KEYMGMT="$WIFI_KEYMGMT" \
  KLH_HIDDEN="$WIFI_HIDDEN" KLH_TEMPLATE="$REPO_DIR/templates/headless-wifi.nmconnection.in" \
  "$GEN" > "$NM_PROFILE"
chmod 0600 "$NM_PROFILE"

# 2) authorized_keys (public data, but keep tight perms anyway)
STAGE_ETC="$KLH_COMMON/includes.chroot/etc/kali-live-headless"
mkdir -p "$STAGE_ETC" "$KLH_COMMON/includes.chroot/etc/default"
install -m 0644 "$SSH_PUBKEY_PATH" "$STAGE_ETC/authorized_keys"
if [ -n "$SSH_EXTRA_PUBKEYS" ]; then
  for k in $SSH_EXTRA_PUBKEYS; do
    k=$(klh_expand_tilde "$k")
    [ -f "$k" ] || klh_die "extra public key not found: $k"
    cat "$k" >> "$STAGE_ETC/authorized_keys"
  done
fi
chmod 0600 "$STAGE_ETC/authorized_keys"

# 3) runtime config consumed by /usr/local/sbin/kali-live-headless-provision
printf '%s\n' "$HOSTNAME" > "$STAGE_ETC/hostname"
chmod 0644 "$STAGE_ETC/hostname"
# template for boot-time regeneration (KLHCONFIG credential override)
install -m 0644 "$REPO_DIR/templates/headless-wifi.nmconnection.in" \
  "$STAGE_ETC/headless-wifi.nmconnection.in"
cat > "$KLH_COMMON/includes.chroot/etc/default/kali-live-headless" <<EOF
# Runtime defaults for kali-live-headless (no secrets here).
WIFI_REGDOM="$WIFI_REGDOM"
# hardware = derive <model>-<cores>c<ram>r<disk>d at boot (mDNS duplicate
# probe adds -2/-3 once the LAN is up); static = use HOSTNAME from ./config
HOSTNAME_SCHEME="$HOSTNAME_SCHEME"
# random = console password randomized every boot (SSH is key-only,
#         sudo passwordless); kali = standard Kali live "kali/kali"
LIVE_PASSWORD_MODE="$LIVE_PASSWORD_MODE"
# WireGuard hub (all NON-secret; the stick generates its own private key on
# first boot — an empty WG_ENDPOINT leaves the whole feature dormant).
WG_ENDPOINT="$WG_ENDPOINT"
WG_PEER_PUBKEY="$WG_PEER_PUBKEY"
WG_TUNNET="$WG_TUNNET"
WG_HUB_ADDR="$WG_HUB_ADDR"
WG_PORT="$WG_PORT"
# BitLocker optimistic unlock (kali-live-bitlocker-mount): off by default;
# "try" lets tooling (vmstore) mount a store on a locked volume when a key
# is available (clear key or KLHCONFIG bitlocker.conf). Never a secret.
VMSTORE_BITLOCKER="$VMSTORE_BITLOCKER"
# TollGate auto-payment mint fallback: handed to tollgate-client when the
# TollGate's advertisement carries no mints (public testnet mint; no secret).
TG_MINT_URL="$TG_MINT_URL"
# FIPS mesh: FIPS_ENABLED gates the whole wire (identity stays); the
# peer values are ./config-only and empty = dormant.
FIPS_ENABLED="$FIPS_ENABLED"
FIPS_PEER_ADDR="$FIPS_PEER_ADDR"
FIPS_PEER_NPUB="$FIPS_PEER_NPUB"
EOF
install -D -m 0644 \
  "$OVERLAY_DIR/includes.chroot/etc/ssh/sshd_config.d/0000-kali-live-headless.conf" \
  "$STAGE_ETC/sshd_config.d/0000-kali-live-headless.conf"

klh_ok "staged overlay + profile + keys into $UPSTREAM_DIR"

fetch_fips_deb

# -------------------------------------------------------------- manifest
MANIFEST="$OUT_DIR/build-manifest-$(date -u '+%Y%m%dT%H%M%SZ').txt"
{
  echo "kali-live-headless build manifest"
  echo "generated (UTC) : $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo "build host      : $(hostname) ($(uname -m))"
  echo "upstream        : $KLH_UPSTREAM_URL"
  echo "upstream ref    : $KALI_LIVE_REF"
  echo "upstream commit : $UPSTREAM_SHA"
  echo "base            : $KLH_BASE ($KLH_DISTRO_NAME $BRANCH)"
  echo "variant/arch    : $VARIANT / $ARCH"
  echo "branch          : $BRANCH"
  echo "hostname        : $HOSTNAME (scheme: $HOSTNAME_SCHEME)"
  echo "wifi ssid       : $WIFI_SSID"
  echo "wifi keymgmt    : $WIFI_KEYMGMT hidden=$WIFI_HIDDEN regdom=${WIFI_REGDOM:-<none>}"
  echo "boot default    : $BOOT_DEFAULT (auto-boot 5s)"
  echo "console password: $LIVE_PASSWORD_MODE"
  echo "kvm stack       : $WITH_KVM"
  echo "authorized keys :"
  awk '{print "  " $1 " " substr($2,1,16) "... " $3}' "$STAGE_ETC/authorized_keys"
  echo "note            : WIFI_PSK deliberately NOT recorded"
} > "$MANIFEST"
klh_ok "manifest: $MANIFEST"

if [ "$DRY_RUN" = true ]; then
  klh_ok "dry run complete — everything staged, nothing built"
  exit 0
fi

# ------------------------------------------------------------------ build
# Reproducible clock. live-build 20250814+kali3 threads SOURCE_DATE_EPOCH
# through every stage that stamps time into the image (bootstrap BUILD_ID,
# binary file mtimes, xorriso --modification-date, squashfs mkfs time) but
# defaults it to `date +%s` when unset — which is exactly why two builds of
# the same commit can differ while sharing a byte size (2026-10-26: #32
# 2454269952 B sha512 30c25031…, #33 2454269952 B sha512 8fc5b712…).
# Pin it to HEAD's commit time: same source ⇒ same clock, by construction.
# Override with KLH_SOURCE_DATE_EPOCH=<epoch> when re-running an old build.
if [ -n "$OPT_SDE" ]; then
  # Identity is (commit, sde). Pinning the clock from the command line is what
  # makes two runs of the same commit comparable even when other commits landed
  # in between — without it, "same source" is not the same clock (2026-10-26:
  # #36 and #37 differed only because a docs commit moved HEAD by 9 minutes).
  case "$OPT_SDE" in (''*[!0-9]*) klh_die "--sde wants a unix epoch, got: $OPT_SDE" ;; esac
  export SOURCE_DATE_EPOCH="$OPT_SDE"
  klh_info "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (pinned with --sde)"
elif [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  if _sde=$(git -C "$REPO_DIR" log -1 --format=%ct 2>/dev/null) && [ -n "$_sde" ]; then
    export SOURCE_DATE_EPOCH="$_sde"
    klh_info "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (HEAD commit time)"
  fi
else
  klh_info "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (inherited from the environment)"
fi

# Build identity for the archive + ledger: what was built, not when.
# Untracked files are ignored on purpose — the build stages trees under
# build/ and output/ that are never part of the source identity.
KLH_BUILD_REF=$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
# `git diff` has no --untracked-files option (it exits 129, which reads as
# "dirty" for every build — builds #36-#40 all claimed -dirty on clean trees);
# `git status --porcelain` is the command that takes it.
if [ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  KLH_BUILD_REF="$KLH_BUILD_REF-dirty"
fi
KLH_BUILD_SDE=${SOURCE_DATE_EPOCH:-unknown}
export KLH_BUILD_REF KLH_BUILD_SDE
klh_info "build identity: $KLH_BUILD_REF sde=$KLH_BUILD_SDE"
SELF_HASH_START=$(sha256sum "$0" | cut -d' ' -f1)
# The ISO is written to a staging dir, never straight into the output dir:
# archiving then moves it into output/iso-buildN/, so a failed or concurrent
# build cannot destroy the previous image.
mkdir -p "$STAGE_OUT"
BUILD_ARGS=(-a "$ARCH" -b "$BRANCH" -v "$VARIANT" -H "$HOSTNAME" -o "$STAGE_OUT")
[ -n "${BUILD_MIRROR:-}" ] && BUILD_ARGS+=(-m "$BUILD_MIRROR")
[ "$KEEP_ARTIFACTS" = true ] && BUILD_ARGS+=(-k)

RC=0
run_upstream() { # $@ = args (no exec: the EXIT trap must still scrub secrets)
  if command -v lb >/dev/null 2>&1 && grep -qi -e '^ID=debian' -e '^ID_LIKE=debian' /usr/lib/os-release 2>/dev/null; then
    klh_info "host is Debian-based with live-build — building directly"
    "$UPSTREAM_DIR/build.sh" "$@" || RC=$?
    return
  fi
  # container path (official upstream Dockerfile)
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      klh_info "building via Docker (official upstream build-in-container.sh)"
      "$UPSTREAM_DIR/build-in-container.sh" "$@" || RC=$?
    else
      klh_info "building via sudo Docker (official upstream build-in-container.sh)"
      sudo -E "$UPSTREAM_DIR/build-in-container.sh" "$@" || RC=$?
    fi
    return
  fi
  klh_die "no build engine: install docker, or run on a Debian/Kali host with live-build"
}

# Kill our build children on Ctrl-C/SIGTERM: a killed wrapper must not leave an
# orphaned `docker run` client behind (that class burned ~1.3 CPU-days before
# anyone noticed, because nothing was holding the container).
BUILD_PID=""
stop_build_children() {
  klh_warn "interrupted — stopping the build"
  if [ -n "$BUILD_PID" ] && kill -0 "$BUILD_PID" 2>/dev/null; then
    kill -TERM "$BUILD_PID" 2>/dev/null || true
  fi
  local ids
  ids=$( { docker ps -q --filter ancestor=kali-build/kali-live 2>/dev/null \
           || sudo -n docker ps -q --filter ancestor=kali-build/kali-live 2>/dev/null; } | tr '\n' ' ' ) || true
  if [ -n "$ids" ]; then
    docker kill $ids 2>/dev/null || sudo -n docker kill $ids 2>/dev/null || true
  fi
  exit 130
}
trap stop_build_children INT TERM

klh_info "starting upstream build (this takes 2-4h and ~20G of disk)"
# Fail fast on base-specific engine requirements (debian: the debootstrap
# keyring must exist in the build container/host — probing takes seconds
# and saves a 45-minute bootstrap death; kali: no-op).
klh_distro_engine_guard
run_upstream "${BUILD_ARGS[@]}" & BUILD_PID=$!
RC=0
wait "$BUILD_PID" || RC=$?
BUILD_PID=""
trap - INT TERM

# Re-assert defaults AFTER the long build call: bash reads scripts
# incrementally, so if this file (or lib/common.sh) is edited while the
# build runs, execution resumes at a byte offset in the NEW file with
# variables the OLD sourced lib never set. Build #8 (2026-10-21) died on
# exactly this AFTER a successful 4-hour build — rc must reflect the
# build, not a wrapper edit. (Rule stands: don't edit scripts mid-run.)
: "${BOOT_DEFAULT:=live}" "${LIVE_PASSWORD_MODE:=random}" \
  "${WITH_KVM:=true}" "${HOSTNAME:=kali-live}" "${OUT_DIR:?}" \
  "${KEEP_ARTIFACTS:=false}" "${ARCHIVE:=true}" "${BUILD_NUM:=?}" "${STAGE_OUT:?}"

if [ "$RC" -ne 0 ]; then
  klh_die "upstream build failed (rc=$RC) — see the log in $OUT_DIR; staged secrets were scrubbed, partial chroot copies may remain under build/kali-live until the next run cleans them"
fi

# post-build integrity: did build.sh change while the build ran? bash reads
# scripts incrementally, so an in-flight edit makes the wrapper resume at a
# byte offset in the NEW file — this killed #8 (rc=1 after a successful 4h
# build) and #18 ('lse: command not found', 2026-10-23). Discipline did not
# survive contact with a long build; this guard is mechanical. The artifact
# itself is safe in the staging dir — only the wrapper steps are unreliable.
SELF_HASH_NOW=$(sha256sum "$0" | cut -d' ' -f1)
if [ "$SELF_HASH_NOW" != "$SELF_HASH_START" ]; then
  klh_die "build.sh was EDITED while this build ran (hash changed). The build SUCCEEDED; the ISO is safe in $STAGE_OUT — re-run the post-build steps by hand: tools/iso-archive.sh --iso $STAGE_OUT/*.iso --build $BUILD_NUM, then ./test.sh --iso <the archived iso>"
fi

# ------------------------------------------------------------ deb pool
# Freeze this build's exact package inputs before the chroot is cleaned up
# (--pool implies --keep-artifacts). The hook staged the .deb set plus a dpkg
# manifest in /var/cache/klh-pool; here it becomes content-addressed objects
# and a per-build apt mirror: docs/reproducible-builds.md.
if [ -n "$POOL_DIR" ]; then
  _pool_src="$UPSTREAM_DIR/chroot/var/cache/klh-pool"
  if [ -d "$_pool_src" ]; then
    klh_info "harvesting this build's .deb set into $POOL_DIR"
    KLH_DEB_POOL="$POOL_DIR" "$REPO_DIR/tools/deb-pool.sh" add \
      --label "b$BUILD_NUM" "$_pool_src" \
      || klh_warn "pool harvest failed — the ISO is unaffected"
    KLH_DEB_POOL="$POOL_DIR" "$REPO_DIR/tools/deb-pool.sh" index \
      --label "b$BUILD_NUM" --suite "${BRANCH:-kali-rolling}" \
      || klh_warn "pool index failed — the ISO is unaffected"
  else
    klh_warn "pool: $_pool_src is missing (the pool hook did not run this build)"
  fi
fi

# ------------------------------------------------------------- archive
STAGE_ISO=$(find "$STAGE_OUT" -maxdepth 1 -name '*.iso' -print -quit 2>/dev/null || true)
[ -n "$STAGE_ISO" ] || klh_die "build reported success (rc=0) but no ISO in $STAGE_OUT"

# ------------------------------------------------- reproducibility verdict
# Identity is (commit, sde), not the build number. If the ledger already holds
# an archived build for this pair, this run is a *reproduction check*: compare
# the bytes and say so, rather than quietly adding a second artifact for the
# same source. The ledger row itself is written by tools/iso-archive.sh.
LEDGER="$OUT_DIR/ledger.tsv"
if [ -f "$LEDGER" ] && [ "$KLH_BUILD_REF" != unknown ] && [ "$KLH_BUILD_SDE" != unknown ]; then
  _prev=$(awk -F'\t' -v r="$KLH_BUILD_REF" -v s="$KLH_BUILD_SDE" \
            'NR>1 && $2==r && $3==s {print $1"\t"$6; exit}' "$LEDGER" 2>/dev/null || true)
  if [ -n "$_prev" ]; then
    _prev_build=${_prev%%$'\t'*}
    _prev_sha=${_prev#*$'\t'}
    _now_sha=$(sha512sum "$STAGE_ISO" | cut -d' ' -f1)
    if [ "$_prev_sha" = "$_now_sha" ]; then
      klh_ok "REPRODUCED: byte-identical to build #$_prev_build ($KLH_BUILD_REF sde=$KLH_BUILD_SDE)"
    else
      klh_warn "MISMATCH: build #$_prev_build has the same commit+clock but different bytes"
      klh_info "  archived: ${_prev_sha:0:32}…"
      klh_info "  this run: ${_now_sha:0:32}…"
      klh_info "  classify: tools/iso-content-diff.sh \"$OUT_DIR/iso-build$_prev_build/${STAGE_ISO##*/}\" \"$STAGE_ISO\""
    fi
  fi
fi

if [ "$ARCHIVE" = true ]; then
  # Marker lets a manual `tools/iso-archive.sh` (no args) archive this build.
  printf 'build=%s\ncommit=%s\nthis-branch\n' \
    "$BUILD_NUM" "$(git -C "$REPO_DIR" rev-parse --short HEAD)" > "$OUT_DIR/.build-current"
  "$REPO_DIR/tools/iso-archive.sh" --iso "$STAGE_ISO" --build "$BUILD_NUM"
  rm -rf "$STAGE_OUT"
  echo
  klh_ok "build #$BUILD_NUM ready: $OUT_DIR/iso-build$BUILD_NUM/$(basename "$STAGE_ISO")"
  klh_info "gate it:  ./test.sh --iso $OUT_DIR/iso-build$BUILD_NUM/$(basename "$STAGE_ISO")"
  klh_info "flash it: ./flash.sh --build $BUILD_NUM"
else
  mv -f "$STAGE_ISO" "$OUT_DIR/"
  [ -f "${STAGE_ISO}.sha512sum" ] && mv -f "${STAGE_ISO}.sha512sum" "$OUT_DIR/"
  [ -f "${STAGE_ISO}.log" ] && mv -f "${STAGE_ISO}.log" "$OUT_DIR/"
  rmdir "$STAGE_OUT" 2>/dev/null || true
  echo
  klh_ok "build finished — artifacts in $OUT_DIR:"
  ls -lh "$OUT_DIR" | tail -n +2 || true
fi
klh_info "next: boot it / ssh kali@${HOSTNAME}.local"
