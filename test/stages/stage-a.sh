# (end Stage A)
# shellcheck disable=SC2034  # *_EXPECTED vars set here are consumed by
# stage-b/stage-cde, which test.sh sources into the SAME shell after this
# file — shellcheck analyzing this file alone cannot see those uses.

# Stage modules are SOURCED by test.sh — a stage sourcing a stage (or
# itself) is an infinite recursion that exhausts bash's stack and dies as
# SIGSEGV rc=139 (found 2026-10-24: the test.sh split left a self-source
# line at the top of every stage file, which also explains the v24 suite's
# rc=139 "silent" death — and every `test.sh | tail` invocation swallowed
# the crash because a pipeline's rc is tail's, so the split-era "static
# green" runs were all vacuous).
if grep -nE '^\s*\.\s.*test/stages/.*stage' "$REPO_DIR"/test/stages/*.sh >/dev/null 2>&1; then
  record fail "no stage sources a stage (self-recursion guard)" "$(grep -hE '^\s*\.\s.*test/stages/.*stage' "$REPO_DIR"/test/stages/*.sh | head -1)"
else
  record pass "no stage sources a stage (self-recursion guard)"
fi

for f in build.sh configure.sh flash.sh test.sh; do
  if bash -n "$REPO_DIR/$f" 2>"$SCRATCH/syntax.err"; then record pass "bash -n $f"; else record fail "bash -n $f" "$(head -1 "$SCRATCH/syntax.err")"; fi
done
for f in overlay/kali-config/common/includes.chroot/usr/local/sbin/* overlay/kali-config/common/hooks/live/*.hook.chroot; do
  # only shell-shebang files: python CLIs legitimately live in sbin too
  # (kali-live-wg-enroll) and must not be bash -n'd as shell
  if head -n1 "$REPO_DIR/$f" | grep -qE '^#![^ ]*(ba)?sh'; then
    if bash -n "$REPO_DIR/$f" 2>/dev/null || sh -n "$REPO_DIR/$f" 2>/dev/null; then record pass "sh -n $(basename "$f")"; else record fail "sh -n $(basename "$f")"; fi
  else
    record pass "sh -n $(basename "$f")" "non-shell shebang, skipped"
  fi
done

# The overlay must never contain compiled artifacts (a stray __pycache__
# shipped into a hotpatch and failed its verify after 60 min of repacking).
if find "$REPO_DIR/overlay" -name "__pycache__" -o -name "*.pyc" | grep -q .; then
  record fail "overlay free of bytecode" "run: find overlay -name __pycache__ -exec rm -rf {} +"
else
  record pass "overlay free of bytecode"
fi

# mksquashfs refuses "/", "./" and "../" prefixed excludes when live-build
# passes -wildcards — and it refuses at the END of a build, after the whole
# chroot has been built (cost: build #36, 2026-10-26). Cheap to check here.
_excl="$REPO_DIR/overlay/kali-config/common/rootfs/excludes"
if [ -f "$_excl" ]; then
  if grep -qE '^[[:space:]]*(/|\./|\.\./)' "$_excl"; then
    record fail "rootfs/excludes paths are squashfs-relative" "strip the leading / — mksquashfs -wildcards rejects it fatally"
  else
    record pass "rootfs/excludes paths are squashfs-relative"
  fi
else
  record skip "rootfs/excludes present" "no excludes file in the overlay"
fi

# An exclude line that is not a plain path (a space, a stray comment tail) is
# silently inert — mksquashfs just matches nothing. That is how a mangled edit
# shipped commands.db.metadata into builds #38/#39 while its sibling was
# excluded correctly.
if [ -f "$_excl" ]; then
  _bad=$(grep -vE '^[[:space:]]*(#|$)' "$_excl" | grep -cE '[[:space:]]' || true)
  if [ "${_bad:-0}" -eq 0 ]; then
    record pass "rootfs/excludes entries are bare paths"
  else
    record fail "rootfs/excludes entries are bare paths" "$_bad line(s) with whitespace — mksquashfs would silently ignore them"
  fi
fi

# A hook live-build cannot execute is silently skipped, so the image ships
# without the step and nothing complains (AGENTS #16: derive_identity.py was
# 100644 for ten builds and never ran). Every hook in the overlay must be +x;
# the reproducibility hooks are the newest members of that class.
for f in "$REPO_DIR"/overlay/kali-config/common/hooks/live/*.hook.chroot \
         "$REPO_DIR"/overlay/kali-config/common/hooks/build/*.hook.*; do
  [ -f "$f" ] || continue
  if [ -x "$f" ]; then
    record pass "hook executable: $(basename "$f")"
  else
    record fail "hook executable: $(basename "$f")" "chmod +x it — live-build skips non-executable hooks"
  fi
done

# POSIX-sh runtime guard. bash -n happily accepts bashisms in #!/bin/sh
# scripts, and dash only reports them at RUNTIME ("Bad substitution") — build
# #11 booted with provision dead on every machine because of \${MODE//\"/}.
# Running shellcheck in sh mode (SC30xx, "In POSIX sh, ... is undefined")
# sees it statically, so this belongs in the 17-second static level, not the
# boot suite.
for f in "$REPO_DIR"/overlay/kali-config/common/includes.chroot/usr/local/sbin/* \
         "$REPO_DIR"/overlay/kali-config/common/hooks/live/*.hook.chroot; do
  [ -f "$f" ] || continue
  [ "$(head -n1 "$f")" = "#!/bin/sh" ] || continue
  if command -v shellcheck >/dev/null 2>&1; then
    posix_bad=$(shellcheck --shell=sh -S info "$f" 2>/dev/null | grep -cE 'SC30[0-9][0-9]' || true)
    if [ "${posix_bad:-0}" -eq 0 ]; then record pass "POSIX sh: $(basename "$f")"; else record fail "POSIX sh: $(basename "$f")" "$(shellcheck --shell=sh -S info "$f" 2>/dev/null | grep -m1 -B2 'SC30[0-9][0-9]' | head -1 | tr -s ' ')"; fi
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  SC="shellcheck"
elif command -v docker >/dev/null 2>&1 && (docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1); then
  docker info >/dev/null 2>&1 && SC="docker" || SC="sudo docker"
else
  SC=""
fi
if [ -n "$SC" ]; then
  if [ "$SC" = "shellcheck" ]; then
    # BOTH streams into sc.out (2026-10-26 vacuous-pass fix: shellcheck
    # prints findings to STDOUT; the old `2>sc.out` left sc.out empty, so
    # the [ -s ] fallback recorded a PASS over a console full of findings).
    # -S warning: same bar as the per-file loop below — the aggregate gates
    # what we keep clean, not the historical info-level noise. The -s sh set
    # is shebang-filtered: python CLIs legitimately live in sbin/ too.
    KLH_SH_HOOKS=()
    for f in "$REPO_DIR"/overlay/kali-config/common/includes.chroot/usr/local/sbin/*; do
      head -n1 "$f" | grep -qE '^#![[:space:]]*([^[:space:]]*/)?(env[[:space:]]+)?(ba|z|da)?sh$' && KLH_SH_HOOKS+=("$f")
    done
    shellcheck -x -S warning "$REPO_DIR"/build.sh "$REPO_DIR"/configure.sh "$REPO_DIR"/flash.sh "$REPO_DIR"/test.sh "$REPO_DIR"/lib/common.sh "$REPO_DIR"/lib/distro/*.sh "$REPO_DIR"/tools/*.sh >"$SCRATCH/sc.out" 2>&1 \
      && shellcheck -s sh -S warning "$REPO_DIR"/overlay/kali-config/common/hooks/live/*.hook.chroot \
                    "${KLH_SH_HOOKS[@]}" >>"$SCRATCH/sc.out" 2>&1 \
      && record pass "shellcheck" || { [ -s "$SCRATCH/sc.out" ] && record fail "shellcheck" "$(grep -c '^' "$SCRATCH/sc.out") findings" || record pass "shellcheck"; }
  else
    $SC run --rm -v "$REPO_DIR:/src:ro" koalaman/shellcheck:stable \
      /src/build.sh /src/configure.sh /src/flash.sh /src/test.sh /src/lib/common.sh /src/lib/distro/*.sh /src/tools/*.sh >"$SCRATCH/sc.out" 2>&1 \
      && $SC run --rm -v "$REPO_DIR:/src:ro" -i koalaman/shellcheck:stable -s sh \
          /src/overlay/kali-config/common/hooks/live/zz-headless-configure.hook.chroot \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-headless-provision \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-console-banner \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wifi-watchdog \
          /src/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-wifi-gen >>"$SCRATCH/sc.out" 2>&1 \
      && record pass "shellcheck (container)" || { [ -s "$SCRATCH/sc.out" ] && record fail "shellcheck (container)" "$(grep -cE ':[0-9]+:[0-9]+:' "$SCRATCH/sc.out" || echo ?) findings" || record pass "shellcheck (container)"; }
  fi
  [ -s "$SCRATCH/sc.out" ] && sed -n '1,20p' "$SCRATCH/sc.out"
else
  record skip "shellcheck" "neither shellcheck nor docker available"
fi

if [ -r "$REPO_DIR/config" ]; then
  record pass "config present"
  if ( source "$REPO_DIR/lib/common.sh" && klh_load_config "$REPO_DIR/config" ) 2>/dev/null; then
    record pass "config validates"
  else
    record fail "config validates" "klh_load_config rejected it"
  fi
else
  record skip "config" "not present — run ./configure.sh"
fi
LEAN_EXPECTED="false"

# load config values if available (non-fatal)
HOSTNAME_EXPECTED="kali-live" HOSTNAME_SCHEME_EXPECTED="hardware" WIFI_SSID_EXPECTED="" PUBKEY_FP_EXPECTED="" SSH_KEY=""
BOOT_DEFAULT_EXPECTED="live" LIVE_PASSWORD_MODE_EXPECTED="random" WITH_KVM_EXPECTED="true" WG_ENDPOINT_EXPECTED="" VARIANT_EXPECTED="minimal" TORAM_EXPECTED="true"
if [ -r "$REPO_DIR/config" ]; then
  rm -f "$SCRATCH/env" "$SCRATCH/pubkeypath"
  # shellcheck disable=SC1091
  ( set -a; source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config"; \
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$HOSTNAME" "$WIFI_SSID" "$BOOT_DEFAULT" "$LIVE_PASSWORD_MODE" "$WITH_KVM" "${WG_ENDPOINT:-}" "$VARIANT" "$TORAM_ENTRY" "${LEAN:-false}" "${HOSTNAME_SCHEME:-hardware}" > "$SCRATCH/env"; \
    printf '%s\n' "$(klh_expand_tilde "$SSH_PUBKEY_PATH")" > "$SCRATCH/pubkeypath" )
  HOSTNAME_EXPECTED=$(sed -n 1p "$SCRATCH/env")
  WIFI_SSID_EXPECTED=$(sed -n 2p "$SCRATCH/env")
  BOOT_DEFAULT_EXPECTED=$(sed -n 3p "$SCRATCH/env")
  LIVE_PASSWORD_MODE_EXPECTED=$(sed -n 4p "$SCRATCH/env")
  WITH_KVM_EXPECTED=$(sed -n 5p "$SCRATCH/env")
  WG_ENDPOINT_EXPECTED=$(sed -n 6p "$SCRATCH/env")
  VARIANT_EXPECTED=$(sed -n 7p "$SCRATCH/env")
  TORAM_EXPECTED=$(sed -n 8p "$SCRATCH/env")
  LEAN_EXPECTED=$(sed -n 9p "$SCRATCH/env")
  HOSTNAME_SCHEME_EXPECTED=$(sed -n 10p "$SCRATCH/env")
  PUBKEY_PATH=$(cat "$SCRATCH/pubkeypath")
  if [ -r "$PUBKEY_PATH" ] && command -v ssh-keygen >/dev/null; then
    if PUBKEY_FP_EXPECTED=$(ssh-keygen -lf "$PUBKEY_PATH" 2>/dev/null | sed 's/^ *[0-9]* //'); then
      record pass "public key parses" "$PUBKEY_FP_EXPECTED"
      KEY_PRIV=${SSH_KEY_ARG:-${PUBKEY_PATH%.pub}}
      [ -n "$SSH_KEY_ARG" ] && KEY_PRIV="$SSH_KEY_ARG"
      if [ -r "$KEY_PRIV" ]; then SSH_KEY="$KEY_PRIV"; record pass "private counterpart available" "$(basename "$SSH_KEY")"; else record skip "private key" "no counterpart of public key — SSH login tests will be skipped"; fi
    else
      record fail "public key parses" "$PUBKEY_PATH"
    fi
  else
    record skip "public key" "path from config unreadable"
  fi
fi

# generate + structurally validate an NM profile via the shared generator
GEN="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-headless-wifi-gen"
if [ -r "$REPO_DIR/config" ] && command -v python3 >/dev/null && [ -x "$GEN" ]; then
  # shellcheck disable=SC1091
  ( source "$REPO_DIR/lib/common.sh"; klh_load_config "$REPO_DIR/config"
    KLH_SSID="$WIFI_SSID" KLH_PSK="$WIFI_PSK" KLH_KEYMGMT="$WIFI_KEYMGMT" \
    KLH_HIDDEN="$WIFI_HIDDEN" KLH_TEMPLATE="$REPO_DIR/templates/headless-wifi.nmconnection.in" \
    "$GEN" > "$SCRATCH/profile.nmconnection" )
  chmod 600 "$SCRATCH/profile.nmconnection"
  python3 - "$SCRATCH/profile.nmconnection" "$WIFI_SSID_EXPECTED" <<'PYEOF' && record pass "NM profile structure" || record fail "NM profile structure"
import sys, configparser
p = configparser.RawConfigParser()
read = p.read(sys.argv[1])
assert read, "ini unreadable"
assert p["connection"]["id"] == "HEADLESS-WIFI"
assert p["connection"]["type"] == "wifi"
assert p["connection"]["autoconnect"] == "true"
assert p["wifi"]["mode"] == "infrastructure"
assert p["wifi"]["ssid"] == sys.argv[2]
assert p["wifi-security"]["key-mgmt"] in ("wpa-psk", "sae")
assert 8 <= len(p["wifi-security"]["psk"]) <= 63
assert "interface-name" not in p["connection"], "must not pin interface-name"
PYEOF
  # keyfile escaping: passphrase with backslash/&/space must round-trip exactly
  KLH_SSID='Esc Net' KLH_PSK='p\ss k&$x9' KLH_KEYMGMT=wpa-psk KLH_HIDDEN=false \
  KLH_TEMPLATE="$REPO_DIR/templates/headless-wifi.nmconnection.in" \
    "$GEN" > "$SCRATCH/profile-esc.nmconnection"
  python3 - "$SCRATCH/profile-esc.nmconnection" <<'PYEOF' && record pass "NM keyfile escaping" || record fail "NM keyfile escaping"
import sys, configparser
raw = open(sys.argv[1]).read()
p = configparser.RawConfigParser()
assert p.read(sys.argv[1]), "ini unreadable"
assert p["wifi"]["ssid"] == "Esc Net", repr(p["wifi"]["ssid"])
# configparser does not emulate GLib unescaping: assert the RAW bytes carry
# the keyfile-escaped form (backslash doubled) that NM/GKeyFile reads back
# as the original single-backslash passphrase.
assert "\npsk=p\\\\ss k&$x9\n" in raw, "psk not escaped for the keyfile format"
PYEOF
  [ "$(stat -c %a "$SCRATCH/profile.nmconnection")" = "600" ] && record pass "NM profile mode 0600" || record fail "NM profile mode 0600"
else
  record skip "NM profile" "no config, python3 or generator"
fi

# host-role mesh identity generator: pure python3 + openssl, no extra deps
ROLE_INIT="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/lib/kali-live-headless/host_role_init.py"
if [ -x "$ROLE_INIT" ] && command -v python3 >/dev/null 2>&1; then
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROLE_INIT" 2>/dev/null \
    && record pass "host-role identity generator compiles" \
    || record fail "host-role identity generator compiles"
else
  record fail "host-role identity generator present+executable"
fi

# Lint pass at WARNING level over everything we ship or run: this is the
# gate that would have caught the console-banner 7-format/8-args bug BEFORE
# commit (found in the 2026-10-25 dead-code/drift review — the KLHCONFIG
# banner line silently dropped the WireGuard line from every future boot).
# NB: comments must NOT start with "shellcheck" — the parser reads any
# such line as a DIRECTIVE and dies (this very header was SC1073-ing
# test.sh's sourced chain until 2026-10-26).
for f in "$REPO_DIR"/overlay/kali-config/common/includes.chroot/usr/local/sbin/* \
         "$REPO_DIR"/overlay/kali-config/common/hooks/live/*.chroot \
         "$REPO_DIR"/overlay/kali-config/common/hooks/build/*.build \
         "$REPO_DIR"/lib/*.sh "$REPO_DIR"/lib/distro/*.sh \
         "$REPO_DIR"/tools/*.sh "$REPO_DIR"/build.sh \
         "$REPO_DIR"/flash.sh "$REPO_DIR"/test.sh; do
  # only shell-shebang files: python CLIs legitimately live in sbin
  # (kali-live-wg-enroll) and must not be parsed as shell. The pattern must
  # accept /usr/bin/env INTERPRETERS — the old '^#![^ ]*(ba|z|da)?sh' matched
  # only direct paths (#!/bin/sh) and silently skipped every '#!/usr/bin/env
  # bash' script: build.sh, flash.sh and test.sh had NO warning-level
  # coverage until 2026-10-26 (vacuous-pass class, AGENTS stage-split lesson)
  head -n1 "$f" | grep -qE '^#![[:space:]]*([^[:space:]]*/)?(env[[:space:]]+)?(ba|z|da)?sh$' || continue
  if shellcheck -S warning "$f" 2>/dev/null; then
    record pass "shellcheck $(basename "$f")"
  else
    record fail "shellcheck $(basename "$f")" "$(shellcheck -S warning -f gcc "$f" 2>/dev/null | grep -m1 warning)"
  fi
done

# Unit tests that are hermetic (no VM, no docker, no hardware) run as part
# of EVERY level — a green suite must include its unit suites (the
# test/stages self-recursion bug showed how easily a suite can "pass" while
# running nothing). Add a dir here ONLY if it needs nothing but coreutils.
UNIT_DIRS="derive-identity stick-registry blackbox"
for d in $UNIT_DIRS; do
  t="$REPO_DIR/test/$d/run-tests.sh"
  if [ ! -x "$t" ]; then record fail "unit $d present" "missing $t"; continue; fi
  # PYTHONDONTWRITEBYTECODE: unit drivers IMPORT modules straight out of
  # overlay/, and the interpreter would drop __pycache__ there — which the
  # bytecode-free check below must not then trip over (order-dependent
  # false FAIL, found 2026-10-25). Manual runs get the same guard from the
  # test scripts themselves.
  if UTOUT=$(PYTHONDONTWRITEBYTECODE=1 bash "$t" 2>&1); then
    record pass "unit $d ($(printf '%s\n' "$UTOUT" | sed -n 's/^pass=\([0-9]*\) fail=.*/\1/p' ) tests)"
  else
    record fail "unit $d" "$(printf '%s\n' "$UTOUT" | grep FAIL | head -1)"
  fi
done
find "$REPO_DIR/overlay" -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

# tools/*.sh must parse as shell too (they run on the OPERATOR host, not in
# the image — syntax errors there cost a flash cycle to discover)
for f in "$REPO_DIR"/tools/*.sh; do
  if bash -n "$f" 2>/dev/null || sh -n "$f" 2>/dev/null; then record pass "sh -n tools/$(basename "$f")"; else record fail "sh -n tools/$(basename "$f")"; fi
done
# stage modules themselves: a stage with a syntax error would only explode
# at boot/content level — minutes-to-hours in — so parse them here (the
# self-recursion class taught that stage bugs surface far too late).
for f in "$REPO_DIR"/test/stages/*.sh; do
  if bash -n "$f" 2>/dev/null; then record pass "bash -n $(basename "$f")"; else record fail "bash -n $(basename "$f")" "$(bash -n "$f" 2>&1 | head -1)"; fi
done

# ---- distro adapter layer (BASE=kali|debian) --------------------------------
# Each adapter must parse, define the full contract (KLH_BASE/OS_ID/NAME,
# default branch), and accept only its own branches; the loader must reject
# anything else. A broken adapter is a BUILD-path defect — assert it at the
# 17-second level, not 3 hours into a build.
for d in "$REPO_DIR"/lib/distro/*.sh; do
  _dname=$(basename "$d" .sh)
  _dout=$(bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro '$_dname'; printf '%s|%s|%s|%s' \"\$KLH_BASE\" \"\$KLH_OS_ID\" \"\$KLH_DISTRO_NAME\" \"\$KLH_DISTRO_DEFAULT_BRANCH\"" 2>&1) || _dout="load failed: $_dout"
  _dflds=$(printf '%s' "$_dout" | tr '|' '\n')
  if [ "$(printf '%s\n' "$_dflds" | sed -n 1p)" = "$_dname" ] \
     && [ -n "$(printf '%s\n' "$_dflds" | sed -n 2p)" ] \
     && bash -n "$d" 2>/dev/null; then
    record pass "distro adapter: $_dname" "os-id $(printf '%s\n' "$_dflds" | sed -n 2p), branch $(printf '%s\n' "$_dflds" | sed -n 4p)"
  else
    record fail "distro adapter: $_dname" "$_dout"
  fi
  # ownership properties: build.sh and the suite branch on these instead
  # of comparing KLH_BASE — a missing/invalid one silently changes build
  # behavior (the flag contract IS the modularity)
  _dprops=$(bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro '$_dname' >/dev/null; printf '%s|%s' \"\${KLH_DISTRO_PIN_BRANCH_WHEN_UNSET:-<unset>}\" \"\${KLH_DISTRO_NEEDS_EXPLICIT_MIRROR:-<unset>}\"" 2>/dev/null)
  case "$_dprops" in
    "true|true"|"true|false"|"false|true"|"false|false") record pass "distro adapter: $_dname ownership properties ($_dprops)" ;;
    *) record fail "distro adapter: $_dname ownership properties" "PIN|MIRROR must each be true or false — got '$_dprops'" ;;
  esac
  # adapter's own branches must validate; a FOREIGN adapter's default
  # branch must be refused (pairwise — every adapter vs every other; no
  # adapter names hardcoded in the suite)
  for _db in $(
    bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro '$_dname'; printf '%s' \"\$KLH_DISTRO_BRANCHES\"" 2>/dev/null
  ); do
    if bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro '$_dname'; klh_distro_validate_branch '$_db'" >/dev/null 2>&1; then
      record pass "distro adapter: $_dname accepts branch $_db"
    else
      record fail "distro adapter: $_dname accepts branch $_db"
    fi
  done
  for _other in "$REPO_DIR"/lib/distro/*.sh; do
    _oname=$(basename "$_other" .sh)
    [ "$_oname" != "$_dname" ] || continue
    _obranch=$(bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro '$_oname'; printf '%s' \"\$KLH_DISTRO_DEFAULT_BRANCH\"" 2>/dev/null)
    if bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro '$_dname'; klh_distro_validate_branch '$_obranch'" >/dev/null 2>&1; then
      record fail "distro adapter: $_dname refuses foreign branch $_obranch ($_oname's default)"
    else
      record pass "distro adapter: $_dname refuses foreign branch $_obranch ($_oname's default)"
    fi
  done
done
if bash -c "source '$REPO_DIR/lib/common.sh'; klh_load_distro nosuchbase" >/dev/null 2>&1; then
  record fail "klh_load_distro rejects unknown BASE"
else
  record pass "klh_load_distro rejects unknown BASE"
fi

# ---- flash.sh base detection (BASE-agnostic flashing) ------------------------
# The flash flow is identical for every base, but the operator must SEE which
# base a stick will boot: flash.sh derives it from the archive manifest. Prove
# all three cases with fixtures: debian manifest, kali manifest, no manifest
# (pre-spike archives and bare --iso paths — must stay kali, the historical
# behavior). --dry-run + </dev/null: the device prompt (if any removable disk
# exists on this host) EOFs into 'aborted' AFTER the pre-flight lines print,
# so the Base line is observable on any host, hardware or not.
mk_flash_fixture() { # $1=dir $2=manifest-base-line ("" = no manifest)
  mkdir -p "$1"
  : > "$1/kali-linux-fixture-live-minimal-amd64.iso"
  [ -n "$2" ] && printf 'base            : %s\n' "$2" > "$1/BUILD-MANIFEST.txt"
}
flash_base_line() { # $1=dir -> the "Base :" pre-flight line
  "$REPO_DIR/flash.sh" --iso "$1/kali-linux-fixture-live-minimal-amd64.iso" --dry-run </dev/null 2>/dev/null \
    | sed -n 's/^Base     : //p'
}
_fbx="$SCRATCH/flash-base"
mk_flash_fixture "$_fbx/debian" "debian (Debian trixie)"
mk_flash_fixture "$_fbx/kali"   "kali (Kali kali-rolling)"
mk_flash_fixture "$_fbx/none"   ""
v=$(flash_base_line "$_fbx/debian")
[ "$v" = "debian — Debian trixie" ] && record pass "flash: base detect — debian manifest" "$v" \
  || record fail "flash: base detect — debian manifest" "got '${v:-<none>}'"
v=$(flash_base_line "$_fbx/kali")
[ "$v" = "kali — Kali kali-rolling" ] && record pass "flash: base detect — kali manifest" "$v" \
  || record fail "flash: base detect — kali manifest" "got '${v:-<none>}'"
v=$(flash_base_line "$_fbx/none")
case "$v" in "kali — Kali (assumed"*) record pass "flash: base detect — no manifest defaults to kali" "$v" ;;
  *) record fail "flash: base detect — no manifest defaults to kali" "got '${v:-<none>}'" ;; esac

# systemd unit sanity
UNITS=(kali-live-headless-provision kali-live-hostname-settle kali-live-console-banner kali-live-wifi-watchdog kali-live-blackbox)
for u in "${UNITS[@]}"; do
  f="$REPO_DIR/overlay/kali-config/common/includes.chroot/etc/systemd/system/$u.service"
  if grep -q '^\[Unit\]' "$f" && grep -q '^\[Service\]' "$f" && grep -q '^\[Install\]' "$f" && grep -q '^ExecStart=' "$f"; then
    record pass "unit $u"
  else
    record fail "unit $u"
  fi
done

# vm-store unit structure (KVM-gated feature; the generic UNITS list above
# must stay build-agnostic)
vmu="$REPO_DIR/overlay/kali-config/common/includes.chroot/etc/systemd/system/kali-live-vmstore-mount.service"
if grep -q '^RemainAfterExit=yes' "$vmu" && grep -q '^ExecStart=/usr/local/sbin/kali-live-vmstore-mount' "$vmu"; then
  record pass "unit kali-live-vmstore-mount (oneshot structure)"
else
  record fail "unit kali-live-vmstore-mount (oneshot structure)"
fi

# ---- vm-store decision-logic unit tests (M1) -------------------------------
# kali-live-vmstore-mount --dry-run + fixtures exercise every gate as a
# non-root user: PATH stubs stand in for ntfs-3g/libvirt (real binaries are
# exercised by the qemu-vmstore boot stage inside the built image).
# rc-capture discipline: assignment first, $? read on the NEXT line.
VMSTORE="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vmstore-mount"
VMCREATE="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-create"
VMRM="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-rm"
FIX="$REPO_DIR/test/fixtures/vm-store"
if [ -x "$VMSTORE" ] && [ -d "$FIX" ]; then
  vmrun() { # conf lsblk [cmdline] -> stdout; rc follows
    ( PATH="$FIX/bin:$PATH" TMPDIR="$SCRATCH" KLH_VMSTORE_CONF="$FIX/$1" KLH_LSBLK_FILE="$FIX/$2" \
      KLH_PROC_CMDLINE="$FIX/${3:-cmdline-live}" "$VMSTORE" --dry-run 2>&1 )
  }
  vm_assert() { # expect_rc conf lsblk [cmdline] description [grep-pattern]
    local expect=$1 conf=$2 lsblk=$3 cmdline=${4:-cmdline-live} desc=$5 pat=${6:-}
    local out rc
    out=$(vmrun "$conf" "$lsblk" "$cmdline")
    rc=$?
    if [ "$expect" = 0 ] && [ "$rc" -ne 0 ]; then record fail "vmstore: $desc" "rc=$rc (want 0)"; return; fi
    if [ "$expect" = 1 ] && [ "$rc" -eq 0 ]; then record fail "vmstore: $desc" "rc=0 (want failure)"; return; fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
      record fail "vmstore: $desc" "plan output missing: $pat"
      return
    fi
    record pass "vmstore: $desc"
  }
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "auto picks the LARGEST ntfs (1.5T, not 500G)" '^plan device=/dev/sda3$'
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "default driver mounts via the ntfs-3g helper" '^plan type=ntfs-3g$'
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "store dir under the mount"               '^plan store_dir=/mnt/klh-vmstore/vms$'
  vm_assert 0 ok.conf      lsblk-normal cmdline-live "uid mapping for the qemu runtime user"    'uid=64055,gid=108,umask=007,windows_names'
  vm_assert 0 label.conf   lsblk-normal cmdline-live "LABEL: selector"                          '^plan device=/dev/sda3$'
  vm_assert 0 uuid.conf    lsblk-normal cmdline-live "PARTUUID: selector"                       '^plan device=/dev/sdb1$'
  vm_assert 0 disabled.conf lsblk-normal cmdline-live "enabled!=true is a quiet no-op"
  vm_assert 0 ok.conf      lsblk-normal cmdline-forensic "forensic boot (noautomount) never mounts"
  vm_assert 1 baddriver.conf lsblk-normal cmdline-live "unknown driver refused"
  vm_assert 1 baddir.conf    lsblk-normal cmdline-live "non-Windows-legal dir refused"
  vm_assert 1 badreserved.conf lsblk-normal cmdline-live "non-numeric reserved_free_mb refused"
  vm_assert 1 ok.conf      lsblk-bitlocker-only cmdline-live "BitLocker-only system with no tool present refused"
  vm_assert 1 ok.conf      lsblk-none cmdline-live "no NTFS candidate refused"
  # the REAL gaming-PC layout (2026-10-23 hardware dry-run): BitLocker C: +
  # a plaintext 1.1G WinRE decoy. auto now goes OPPORTUNISTIC (owner
  # directive): the plan is always try-mount and only BitLocker volumes
  # can ever be unlocked — the decoy is structurally unselectable.
  # Consent (stick bitlocker=try|off incl. veto, or the staged gate) is
  # kali-live-bitlocker-mount's consent() (ce38904+); its refusal at
  # runtime fails the service with the remediation in the journal.
  ( export KLH_BLKM="$FIX/bin/kali-live-bitlocker-mount-stub"
    vm_assert 0 ok.conf      lsblk-real-gamingpc cmdline-live "auto + BitLocker plans the opportunistic unlock" '^plan bitlocker=yes$'
    vm_assert 0 ok.conf      lsblk-real-gamingpc cmdline-live "auto unlock goes through try-mount" '^plan unlock=try-mount:'
    vm_assert 0 blk-target.conf lsblk-real-gamingpc cmdline-live "explicit BitLocker target plans try-mount" '^plan bitlocker=yes$' )
  ( export KLH_BLKM="/nonexistent/bitlocker-mount"
    vm_assert 1 blk-target.conf lsblk-real-gamingpc cmdline-live "BitLocker target refused when the unlock tool is missing (pre-v18 image)" )
  # garbage consent value never reaches the tool
  ( export KLH_BLKM="$FIX/bin/kali-live-bitlocker-mount-stub"
    vm_assert 1 blk-bad.conf lsblk-real-gamingpc cmdline-live "bitlocker=sure refused (try|off only)" )
  # the recommended plaintext path: dedicated VMSTORE partition by LABEL on
  # exactly that machine (explicit selector, BitLocker elsewhere ignored)
  vm_assert 0 vmstore-partition.conf lsblk-with-vmstore cmdline-live "LABEL:VMSTORE picks the dedicated partition on a BitLocker box" '^plan device=/dev/nvme0n1p3$'
  if grep -qw ntfs3 /proc/filesystems 2>/dev/null; then
    vm_assert 0 ntfs3.conf  lsblk-normal cmdline-live "explicit ntfs3 driver resolves when the kernel has it" '^plan type=ntfs3$'
  else
    record skip "vmstore: explicit ntfs3 driver" "host kernel has no ntfs3 (assert would be the refusal path)"
    vm_assert 1 ntfs3.conf lsblk-normal cmdline-live "ntfs3 refused when the kernel lacks the module"
  fi

  # vm-create / -rm argument + state guards (host, no store present)
  if "$VMCREATE" --id 'Bad/Name' --cores 1 --ram-gb 1 --disk-gb 1 >/dev/null 2>&1; then
    record fail "vm-create: refuses non-[a-z0-9-] id"
  else
    record pass "vm-create: refuses non-[a-z0-9-] id"
  fi
  out=$("$VMCREATE" --id goodvm --cores 1 --ram-gb 1 --disk-gb 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not mounted' \
    && record pass "vm-create: refuses without an active store" \
    || record fail "vm-create: refuses without an active store" "rc=$rc out=$out"
  if "$VMRM" --id x --stale >/dev/null 2>&1; then
    record fail "vm-rm: --id + --stale are mutually exclusive"
  else
    record pass "vm-rm: --id + --stale are mutually exclusive"
  fi
  out=$("$VMRM" --stale 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'not mounted' \
    && record pass "vm-rm: --stale refuses to run without the store" \
    || record fail "vm-rm: --stale refuses to run without the store" "rc=$rc out=$out"
else
  record skip "vmstore unit tests" "script/fixtures missing"
fi

  # stick-conf.sh --vm-store: the flash-time seeding contract (flash.sh
  # writes vm-store.conf onto KLHCONFIG from this output)
  SC="$REPO_DIR/scripts/stick-conf.sh"
  cat > "$SCRATCH/vmstore-on.conf" <<'SCCFG'
HOSTNAME=kali-live
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
WIFI_KEYMGMT=wpa-psk
VMSTORE_ENABLED=true
VMSTORE_PARTITION=PARTUUID:ec732c5b-3eed-409b-b0ef-ba6964f19af0
VMSTORE_DIR=vms
VMSTORE_RESERVED_MB=20480
VMSTORE_BITLOCKER=try
SCCFG
  cat > "$SCRATCH/vmstore-off.conf" <<'SCCFG'
HOSTNAME=kali-live
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
VMSTORE_ENABLED=false
SCCFG
  cat > "$SCRATCH/vmstore-bad.conf" <<'SCCFG'
HOSTNAME=kali-live
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
VMSTORE_ENABLED=true
VMSTORE_DIR=../etc
SCCFG
  out=$("$SC" --vm-store --config "$SCRATCH/vmstore-on.conf" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^partition=PARTUUID:ec732c5b' && printf '%s' "$out" | grep -q '^bitlocker=try$' \
    && record pass "stick-conf --vm-store renders the enabled store" \
    || record fail "stick-conf --vm-store renders the enabled store" "rc=$rc"
  "$SC" --vm-store --config "$SCRATCH/vmstore-off.conf" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 3 ] && record pass "stick-conf --vm-store exits 3 when disabled" || record fail "stick-conf --vm-store exits 3 when disabled" "rc=$rc"
  "$SC" --vm-store --config "$SCRATCH/vmstore-bad.conf" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then record pass "stick-conf --vm-store rejects garbage config"; else record fail "stick-conf --vm-store rejects garbage config" "rc=$rc"; fi

# tools regression: iso-prune's reclaimable-total must count BYTES (fixed in
# dd76fd8). du's default output unit is KiB while numfmt --to=iec expects
# bytes, so the pre-fix dry run printed a ~22G reclaimable set as "22M". Fake
# two archives (candidate 3 MiB with sidecars, kept-newest 5 MiB deliberately
# PARTIAL — no sidecars), dry-run the real script against them, and require:
# the run to complete (a sidecar-less archive used to kill the table silently
# under set -e), and the printed total to be the candidate's byte count — the
# KiB-units bug lands 1024x below the floor, and counting kept archives too
# lands above the ceiling.
if command -v numfmt >/dev/null 2>&1; then
  prune_dir="$SCRATCH/prune-regr"
  prune_iso="kali-linux-rolling-live-amd64.iso"
  mkdir -p "$prune_dir/iso-build1" "$prune_dir/iso-build2"
  head -c 3145728 /dev/urandom >"$prune_dir/iso-build1/$prune_iso"
  head -c 5242880 /dev/urandom >"$prune_dir/iso-build2/$prune_iso"
  ( cd "$prune_dir/iso-build1" && sha512sum "$prune_iso" >"$prune_iso.sha512sum" )
  printf '## Verdict\n\nfixture, not a real build\n' >"$prune_dir/iso-build1/INDEX.md"
  prune_rc=0
  prune_out=$(OUT_DIR="$prune_dir" "$REPO_DIR/tools/iso-prune.sh" 2>&1) || prune_rc=$?
  if [ "$prune_rc" -eq 0 ]; then
    record pass "iso-prune: dry run completes" "partial (sidecar-less) newest archive tolerated"
  else
    record fail "iso-prune: dry run completes" "rc=$prune_rc — partial archive kills the table under set -e; last line: $(printf '%s' "$prune_out" | tail -1)"
  fi
  prune_got=$(printf '%s\n' "$prune_out" | sed -n 's/^ \* reclaimable: //p' | tail -1)
  prune_b=$(numfmt --from=iec "${prune_got:-0}" 2>/dev/null) || prune_b=0
  if [ "${prune_b:-0}" -ge 2831155 ] && [ "${prune_b:-0}" -le 6291456 ]; then
    record pass "iso-prune: reclaimable-total counts bytes" "dry-run printed '$prune_got' (3 MiB candidate; the 5 MiB newest archive is kept, not counted)"
  else
    record fail "iso-prune: reclaimable-total counts bytes" "printed '${prune_got:-nothing}' (${prune_b:-0} B parsed) — want ≈3.1M; the pre-dd76fd8 du-units bug prints 3.0K here"
  fi
else
  record skip "iso-prune: reclaimable-total counts bytes" "numfmt not available"
fi

# vm-forward state persistence guard: reassert (a systemd timer, env-less)
# and remove must reinstall exactly what add installed — the effective iface
# list has to live in the rule file (netns-proven 2026-10-23: an
# override-added DNAT silently vanished on the next env-less reassert
# before this), not in whatever environment reappraisal happens to have.
vmfw_script="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-forward"
if grep -qF 'IFACES="%s"' "$vmfw_script" && [ "$(grep -c 'IFACES:-\$EXT_IFACES' "$vmfw_script")" -ge 2 ]; then
  record pass "vm-forward: add/remove/reassert share the persisted IFACES"
else
  record fail "vm-forward: add/remove/reassert share the persisted IFACES" "the rule file must carry IFACES and BOTH remove and reassert must fall back to it"
fi

# ---- tollgate-watchdog decision matrix (fixture-driven, no NetworkManager)----
# The watchdog is the fail-safe for the TollGate connectivity experiment:
# these assert its DECISIONS with stub inputs (the vm-store fixture pattern):
# house mode is a no-op; the open network starts a deadline; internet within
# it = ok; past it with no internet = force the house profile (and with
# KLH_TG_REBOOT=true + fallback not taking, the reboot escalation — which
# the clock-file guard makes test-safe: a fake clock means never actually reboot).
TGW="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-tollgate-watchdog"
if [ -x "$TGW" ]; then
  record pass "tollgate watchdog shipped+executable"

  tgw_env() { # dir con probe clock
    rm -rf "$1"; mkdir -p "$1"
    printf '%s\n' "$2" > "$1/nm"
    printf '%s\n' "$3" > "$1/probe"
    printf '%s' "$4" > "$1/clock"
  }
  D="$SCRATCH/tgw"
  tgw_env "$D/house" "headless-wifi:802-11-wireless" ok 100
  KLH_STATE_DIR="$D/house" KLH_NMCLI_FILE="$D/house/nm" KLH_INET_PROBE_FILE="$D/house/probe" KLH_CLOCK_FILE="$D/house/clock" "$TGW" --once
  [ "$?" = 0 ] && grep -q '^house - ok' "$D/house/tollgate-status" && [ ! -e "$D/house/nm.calls" ] \
    && record pass "tollgate watchdog: house mode is a no-op" || record fail "tollgate watchdog: house mode is a no-op"

  tgw_env "$D/first" "tollgate-open:802-11-wireless" fail 100
  KLH_STATE_DIR="$D/first" KLH_NMCLI_FILE="$D/first/nm" KLH_INET_PROBE_FILE="$D/first/probe" KLH_CLOCK_FILE="$D/first/clock" "$TGW" --once
  grep -q 'tollgate .* waiting' "$D/first/tollgate-status" \
    && record pass "tollgate watchdog: open network starts the deadline" || record fail "tollgate watchdog: open network starts the deadline"

  tgw_env "$D/paid" "tollgate-open:802-11-wireless" ok 130
  cp "$D/first/tollgate-since" "$D/paid/tollgate-since" 2>/dev/null
  KLH_STATE_DIR="$D/paid" KLH_NMCLI_FILE="$D/paid/nm" KLH_INET_PROBE_FILE="$D/paid/probe" KLH_CLOCK_FILE="$D/paid/clock" "$TGW" --once
  grep -q 'tollgate .* ok' "$D/paid/tollgate-status" && [ ! -e "$D/paid/nm.calls" ] \
    && record pass "tollgate watchdog: internet within deadline = ok, no fallback" || record fail "tollgate watchdog: internet within deadline = ok, no fallback"

  tgw_env "$D/dead" "tollgate-open:802-11-wireless" fail 400
  cp "$D/first/tollgate-since" "$D/dead/tollgate-since" 2>/dev/null
  KLH_STATE_DIR="$D/dead" KLH_NMCLI_FILE="$D/dead/nm" KLH_INET_PROBE_FILE="$D/dead/probe" KLH_CLOCK_FILE="$D/dead/clock" KLH_TG_HOUSE_PROFILE=headless-wifi "$TGW" --once
  tgwrc=0; [ -f "$D/dead/nm.calls" ] || tgwrc=1
  grep -q 'con-up headless-wifi' "$D/dead/nm.calls" 2>/dev/null && grep -q 'fell-back' "$D/dead/tollgate-status" && [ "$tgwrc" = 0 ] \
    && record pass "tollgate watchdog: deadline+no internet forces the house profile" || record fail "tollgate watchdog: deadline+no internet forces the house profile"

  tgw_env "$D/reboot" "tollgate-open:802-11-wireless" fail 400
  cp "$D/first/tollgate-since" "$D/reboot/tollgate-since" 2>/dev/null
  KLH_STATE_DIR="$D/reboot" KLH_NMCLI_FILE="$D/reboot/nm" KLH_INET_PROBE_FILE="$D/reboot/probe" KLH_CLOCK_FILE="$D/reboot/clock" KLH_TG_REBOOT=true "$TGW" --once
  grep -q 'rebooting' "$D/reboot/tollgate-status" \
    && record pass "tollgate watchdog: opt-in reboot escalation (test-safe via fake clock)" || record fail "tollgate watchdog: reboot escalation"
else
  record fail "tollgate watchdog shipped+executable"
fi

# ---- tollgate trigger decision matrix (fixture-driven, no network) ----
# The trigger is what pays for internet on open networks; these assert its
# DECISIONS with stubs (KLH_TG_CLIENT/ROUTE_FILE/PROBE_FILE indirection —
# the watchdog fixture pattern): no TollGate = clean skip; TollGate + staged
# TG_MINT_URL = client invoked WITH --mint (the degraded-advert fallback);
# TollGate + no staged mint = client invoked bare.
TGT="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-tollgate"
if [ -x "$TGT" ]; then
  record pass "tollgate trigger shipped+executable"
  T="$SCRATCH/tgt"
  mkdir -p "$T"
  cat > "$T/client-stub" <<'STUB'
#!/bin/sh
echo "$@" >> "$(dirname "$0")/client.calls"
exit 0
STUB
  chmod +x "$T/client-stub"

  printf '10.0.0.1\n' > "$T/route"
  printf 'tollgate\n' > "$T/probe-yes"
  printf 'empty\n'    > "$T/probe-no"
  : > "$T/defaults"

  KLH_TG_CLIENT="$T/client-stub" KLH_TG_ROUTE_FILE="$T/route" KLH_TG_PROBE_FILE="$T/probe-no" KLH_TG_DEFAULTS="$T/defaults" "$TGT" >/dev/null 2>&1
  [ ! -e "$T/client.calls" ] \
    && record pass "tollgate trigger: no TollGate on the gateway = clean skip (client not invoked)" \
    || record fail "tollgate trigger: no TollGate = clean skip"

  rm -f "$T/client.calls"
  printf 'TG_MINT_URL=https://testnut.cashu.space\n' > "$T/defaults"
  KLH_TG_CLIENT="$T/client-stub" KLH_TG_ROUTE_FILE="$T/route" KLH_TG_PROBE_FILE="$T/probe-yes" KLH_TG_DEFAULTS="$T/defaults" "$TGT" >/dev/null 2>&1
  grep -q -- '--gateway 10.0.0.1 --mint https://testnut.cashu.space' "$T/client.calls" 2>/dev/null \
    && record pass "tollgate trigger: staged TG_MINT_URL passed as --mint (degraded-advert fallback)" \
    || record fail "tollgate trigger: staged TG_MINT_URL passed as --mint"

  rm -f "$T/client.calls"
  : > "$T/defaults"
  KLH_TG_CLIENT="$T/client-stub" KLH_TG_ROUTE_FILE="$T/route" KLH_TG_PROBE_FILE="$T/probe-yes" KLH_TG_DEFAULTS="$T/defaults" "$TGT" >/dev/null 2>&1
  grep -q -- '--gateway 10.0.0.1$' "$T/client.calls" 2>/dev/null \
    && record pass "tollgate trigger: no staged mint = client invoked bare" \
    || record fail "tollgate trigger: no staged mint = bare invocation"
else
  record fail "tollgate trigger shipped+executable"
fi

# ============================================ hardware-derived hostname
# The boot-time name is <model>-<cores>c<ram>r<disk>d (x280-8c16r256d).
# Derivation is pure sysfs/procfs parsing, so it is unit-testable here from
# fixtures — the boot stages only prove the QEMU machine's own name, which
# cannot exercise Lenovo DMI, dm-*/zram exclusion, or the duplicate probe.
HWD="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-hostname-derive"
HWS="$REPO_DIR/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-hostname-settle"
if [ -x "$HWD" ]; then
  record pass "hostname derive shipped+executable"
  HW="$SCRATCH/hw"; mkdir -p "$HW/dmi" "$HW/sys/block"
  # Lenovo X280 (the machine this feature was written for): product_version
  # is the descriptive string, product_name is the SKU. 8 threads, 15.5 GiB
  # (label: 16), 500118192 sectors = 256 GB. dm-0/zram0/loop0 must be ignored.
  printf '20KE003KMX\n'      > "$HW/dmi/product_name"
  printf 'ThinkPad X280\n'   > "$HW/dmi/product_version"
  printf 'ThinkPad X280\n'   > "$HW/dmi/product_family"
  printf 'MemTotal:       16255472 kB\n' > "$HW/meminfo"
  for d in nvme0n1 loop0 zram0 dm-0; do mkdir -p "$HW/sys/block/$d"; echo 0 > "$HW/sys/block/$d/removable"; done
  echo 500118192 > "$HW/sys/block/nvme0n1/size"
  echo 4000      > "$HW/sys/block/loop0/size"
  echo 32509952  > "$HW/sys/block/zram0/size"
  echo 999999999 > "$HW/sys/block/dm-0/size"
  out=$(KLH_DMI_DIR="$HW/dmi" KLH_SYSBLOCK="$HW/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=8 "$HWD" --no-probe 2>/dev/null)
  [ "$out" = "x280-8c16r256d" ] \
    && record pass "hostname derive: Lenovo X280 -> x280-8c16r256d" \
    || record fail "hostname derive: Lenovo X280 -> x280-8c16r256d" "got '$out'"
  klh_validate_hostname "$out" \
    && record pass "hostname derive: output passes hostname(7) rules" \
    || record fail "hostname derive: output passes hostname(7) rules" "'$out'"

  # Dell: product_version is a DMI placeholder, model lives in product_name;
  # sda is the live medium in this run, so no disk component must appear
  # (a stick-less machine descends to model+cores+RAM instead of counting
  # the boot medium's size as hardware).
  HW2="$SCRATCH/hw-dell"; mkdir -p "$HW2/dmi" "$HW2/sys/block/sda"
  printf 'Latitude 7490\n'      > "$HW2/dmi/product_name"
  printf 'Not Specified\n'      > "$HW2/dmi/product_version"
  : > "$HW2/dmi/product_family"; : > "$HW2/dmi/board_name"
  echo 0 > "$HW2/sys/block/sda/removable"
  echo 250069680 > "$HW2/sys/block/sda/size"
  out=$(KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 KLH_MEDIUM_SRC=/dev/sda "$HWD" --no-probe 2>/dev/null)
  [ "$out" = "latitude-7490-4c16r" ] \
    && record pass "hostname derive: DMI placeholder skipped + live medium not counted as disk" \
    || record fail "hostname derive: DMI placeholder skipped + live medium not counted as disk" "got '$out'"

  # A bare vendor version string in product_version ("1.0") names nothing and
  # must fall through to product_name instead of producing "1-0-...".
  printf '1.0\n' > "$HW2/dmi/product_version"
  out=$(KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 KLH_MEDIUM_SRC=/dev/sda "$HWD" --no-probe 2>/dev/null)
  printf 'Not Specified\n' > "$HW2/dmi/product_version"
  [ "$out" = "latitude-7490-4c16r" ] \
    && record pass "hostname derive: bare version string skipped" \
    || record fail "hostname derive: bare version string skipped" "got '$out'"

  # Desktop/big-core case (Lenovo Legion-class tower): 20 cores, 32 GiB
  # installed (MemTotal ~31 GiB — must round UP to 32r), 1 TB NVMe + a 2 TB
  # SATA data disk (NVMe wins). Model comes from product_version;
  # product_name is the SKU.
  HW3="$SCRATCH/hw-legion"; mkdir -p "$HW3/dmi" "$HW3/sys/block/nvme0n1" "$HW3/sys/block/sda"
  printf '90RC00ABCD
'          > "$HW3/dmi/product_name"
  printf 'Legion T5 26AMR5\n'    > "$HW3/dmi/product_version"
  printf 'Legion T5 26AMR5\n'    > "$HW3/dmi/product_family"
  : > "$HW3/dmi/board_name"
  printf 'MemTotal:       32400000 kB\n' > "$HW3/meminfo"
  echo 0 > "$HW3/sys/block/nvme0n1/removable"
  echo 1953525168 > "$HW3/sys/block/nvme0n1/size"
  # ...plus a larger secondary SATA disk: the NVMe must win (desktops pair a
  # fast system drive with a big data disk; naming the machine after the
  # data disk would be wrong).
  echo 0 > "$HW3/sys/block/sda/removable"
  echo 4000787030016 > "$HW3/sys/block/sda/size"
  out=$(KLH_DMI_DIR="$HW3/dmi" KLH_SYSBLOCK="$HW3/sys/block" KLH_MEMINFO="$HW3/meminfo" \
        KLH_NPROC=20 "$HWD" --no-probe 2>/dev/null)
  [ "$out" = "legion-t5-26amr5-20c32r1000d" ] \
    && record pass "hostname derive: 20-core Legion tower -> legion-t5-26amr5-20c32r1000d" \
    || record fail "hostname derive: 20-core Legion tower" "got '$out'"

  # Duplicate resolution: base and -2 already answered by another host ->
  # -3. Uses the documented KLH_PROBE_CMD/KLH_OWN_ADDRS hooks.
  cat > "$SCRATCH/probe-dupe.sh" <<'PROBE'
#!/bin/sh
case "$1" in
  latitude-7490-4c16r128d|latitude-7490-4c16r128d-2) echo 192.0.2.50 ;;
  *) exit 1 ;;
esac
PROBE
  chmod +x "$SCRATCH/probe-dupe.sh"
  out=$(KLH_PROBE_CMD="$SCRATCH/probe-dupe.sh" KLH_OWN_ADDRS=192.0.2.217 \
        KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 "$HWD" 2>/dev/null)
  [ "$out" = "latitude-7490-4c16r128d-3" ] \
    && record pass "hostname derive: duplicate probe suffixes -3 (base and -2 taken)" \
    || record fail "hostname derive: duplicate probe suffixes -3 (base and -2 taken)" "got '$out'"

  # Our OWN mDNS answer is not a duplicate (the probe must exclude this
  # machine's addresses, or every boot would rename itself to -2).
  cat > "$SCRATCH/probe-self.sh" <<'PROBE'
#!/bin/sh
echo 192.0.2.217
PROBE
  chmod +x "$SCRATCH/probe-self.sh"
  out=$(KLH_PROBE_CMD="$SCRATCH/probe-self.sh" KLH_OWN_ADDRS=192.0.2.217 \
        KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 "$HWD" 2>/dev/null)
  [ "$out" = "latitude-7490-4c16r128d" ] \
    && record pass "hostname derive: own mDNS answer is not a duplicate" \
    || record fail "hostname derive: own mDNS answer is not a duplicate" "got '$out'"

  # Regression (found live on hotpatch #32): avahi also publishes site-local
  # (fec0::, QEMU user-net's IPv6 subnet) and link-local (fe80::) addresses.
  # `ip addr show scope global` omitted them, so a SELF answer looked foreign
  # and every boot falsely gained '-2'. A fake `ip` with all scopes + a fec0
  # self-answer must stay on the base name; a genuinely foreign address must
  # still suffix.
  mkdir -p "$SCRATCH/fakebin"
  cat > "$SCRATCH/fakebin/ip" <<'IP'
#!/bin/sh
printf '%s\n' \
  '1: lo    inet 127.0.0.1/8 scope host lo' \
  '2: eth0    inet 192.0.2.217/24 scope global eth0' \
  '2: eth0    inet6 fec0::2/64 scope site eth0' \
  '2: eth0    inet6 fe80::1/64 scope link eth0'
IP
  chmod +x "$SCRATCH/fakebin/ip"
  cat > "$SCRATCH/probe-fec0.sh" <<'PROBE'
#!/bin/sh
case "$1" in
  latitude-7490-4c16r128d) echo fec0::2 ;;
  *) exit 1 ;;
esac
PROBE
  chmod +x "$SCRATCH/probe-fec0.sh"
  out=$(PATH="$SCRATCH/fakebin:$PATH" KLH_PROBE_CMD="$SCRATCH/probe-fec0.sh" \
        KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 "$HWD" 2>/dev/null)
  [ "$out" = "latitude-7490-4c16r128d" ] \
    && record pass "hostname derive: site-local/link-local self-answer is not a duplicate" \
    || record fail "hostname derive: site-local self-answer" "got '$out' (avahi publishes fec0::/fe80:: too)"

  cat > "$SCRATCH/probe-lo.sh" <<'PROBE'
#!/bin/sh
case "$1" in
  latitude-7490-4c16r128d) echo 127.0.0.1 ;;
  *) exit 1 ;;
esac
PROBE
  chmod +x "$SCRATCH/probe-lo.sh"
  out=$(PATH="$SCRATCH/fakebin:$PATH" KLH_PROBE_CMD="$SCRATCH/probe-lo.sh" \
        KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 "$HWD" 2>/dev/null)
  [ "$out" = "latitude-7490-4c16r128d" ] \
    && record pass "hostname derive: loopback self-answer (avahi publishes 127.0.0.1) is not a duplicate" \
    || record fail "hostname derive: loopback self-answer" "got '$out' (avahi registers 127.0.0.1 for our own name)"

  cat > "$SCRATCH/probe-foreign.sh" <<'PROBE'
#!/bin/sh
case "$1" in
  latitude-7490-4c16r128d) echo 192.0.2.99 ;;
  *) exit 1 ;;
esac
PROBE
  chmod +x "$SCRATCH/probe-foreign.sh"
  out=$(PATH="$SCRATCH/fakebin:$PATH" KLH_PROBE_CMD="$SCRATCH/probe-foreign.sh" \
        KLH_DMI_DIR="$HW2/dmi" KLH_SYSBLOCK="$HW2/sys/block" KLH_MEMINFO="$HW/meminfo" \
        KLH_NPROC=4 "$HWD" 2>/dev/null)
  [ "$out" = "latitude-7490-4c16r128d-2" ] \
    && record pass "hostname derive: a genuinely foreign answer still suffixes -2" \
    || record fail "hostname derive: foreign answer still suffixes" "got '$out'"

  # Underscore is not a legal hostname character: the counter MUST be a dash
  # (the requested "_2" form would break avahi/DNS/cert SANs).
  case "$out" in *_) record fail "hostname derive: counter uses '-' not '_'" ;; esac
else
  record fail "hostname derive shipped+executable"
fi
if [ -x "$HWS" ]; then
  record pass "hostname settle shipped+executable"
else
  record fail "hostname settle shipped+executable"
fi
if grep -q '^HOSTNAME_SCHEME=' "$REPO_DIR/config.example"; then
  record pass "config.example documents HOSTNAME_SCHEME"
else
  record fail "config.example documents HOSTNAME_SCHEME"
fi

# stick-conf must NOT write an explicit HOSTNAME= for the hardware scheme:
# that line is the highest-precedence override at boot, so flashing would
# pin every stick to the build host's ./config name and silently disable
# HOSTNAME_SCHEME=hardware.
SCC="$REPO_DIR/scripts/stick-conf.sh"
if [ -x "$SCC" ]; then
  SHC="$SCRATCH/stick-hw.conf"
  cat > "$SHC" <<'SCCFG'
WIFI_SSID=SomeNet
WIFI_PSK=SomePassphrase123
WIFI_KEYMGMT=wpa-psk
WIFI_HIDDEN=false
WIFI_REGDOM=US
HOSTNAME=kali-live
HOSTNAME_SCHEME=hardware
SCCFG
  out=$("$SCC" --config "$SHC" 2>/dev/null)
  if printf '%s' "$out" | grep -q '^HOSTNAME='; then
    record fail "stick-conf: hardware scheme omits HOSTNAME override" "flashed sticks would be pinned to the build name"
  else
    record pass "stick-conf: hardware scheme omits HOSTNAME override"
  fi
  sed -i 's/^HOSTNAME_SCHEME=hardware$/HOSTNAME_SCHEME=static/' "$SHC"
  out=$("$SCC" --config "$SHC" 2>/dev/null)
  printf '%s' "$out" | grep -q '^HOSTNAME=kali-live$' \
    && record pass "stick-conf: static scheme writes HOSTNAME override" \
    || record fail "stick-conf: static scheme writes HOSTNAME override"
else
  record skip "stick-conf hostname scheme" "script missing"
fi
