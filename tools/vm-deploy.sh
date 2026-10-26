#!/usr/bin/env bash
# vm-deploy.sh — create an internet-reachable VM on the kali-live-headless
#                VM host, publish exactly one SSH port on the concentrator,
#                and verify egress + isolation from where you sit.
#
# One command does the whole stack:
#
#   laptop ──ssh──> VM host (stick)      kali-live-vm-deploy: volume, seed,
#                                         domain, egress policy, port forward
#          ──ssh──> concentrator (inr2)  hub-enroll-stick + hub-vm-forward:
#                                         WireGuard peer + DNAT unit
#          ──ssh──> public port          verification: egress IP, isolation,
#                                         sshd posture
#
# Usage:
#   tools/vm-deploy.sh --name NAME --cores N --ram-gb N --disk-gb N
#                      [--ssh-key KEY_OR_FILE]... [--guest-user debian]
#                      [--port N] [--stick kali@kali-live.local]
#                      [--hub root@inr2.cashu.exchange] [--no-hub]
#                      [--no-egress] [--wait SECONDS] [--restore]
#
#   --ssh-key     public key to authorize in the guest (literal or .pub path).
#                 Repeatable; defaults to ~/.ssh/id_ed25519.pub. The VM host
#                 also adds its own management key.
#   --port        external SSH port on the concentrator (auto-picked on the
#                 host from 22023 upward when omitted).
#   --stick/--hub ssh targets for the VM host and the concentrator.
#   --no-hub      provision on the stick only (guest stays reachable on the
#                 LAN, no public port, no WireGuard enrollment).
#   --no-egress   keep the guest on the host's uplink instead of the tunnel.
#   --restore     re-define/start an existing guest (after a VM-host reboot);
#                 no volume or seed is created.
#   --adopt       take over a hand-built (pre-tool) guest: save its XML, move a
#                 RAM-only seed onto the store, record state, publish it.
#   --verify-only skip provisioning; re-run the checks against a running guest
#                 (uses --name/--port or the state file on the VM host).
#   --no-check    skip the end-of-deploy checklist (tools/vm-check.sh --postflight);
#                 the checklist proves the properties the six deploy checks do
#                 not (persistence artifacts, cross-VM isolation, DNS pinning,
#                 authorized keys, port ownership).
#   --fips        give the guest its own FIPS mesh identity (kali-live-vm-fips):
#                 nsec/npub derived from the stick's salt + the guest uuid,
#                 daemon + fips-dns installed in the guest. Identity-only when
#                 no --fips-peer is given (same split as the host's mesh).
#   --fips-peer   static peer for the guest's fips, "npub...@host:port"
#                 (repeatable; implies --fips).
#
# Exit codes: 0 all steps + verification passed, 1 any step or check failed.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)

NAME="" CORES="" RAM_GB="" DISK_GB="" GUEST_USER=debian PORT=""
STICK="kali@kali-live.local" HUB="root@inr2.cashu.exchange"
NO_HUB=false NO_EGRESS=false RESTORE=false ADOPT=false VERIFY_ONLY=false WAIT=300 STATE=""
NO_CHECK=false FIPS=false
FIPS_PEERS=()
KEYS=()

pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }
step() { printf '\n== %s\n' "$1"; }
die()  { printf 'vm-deploy: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)       NAME=${2:?}; shift 2 ;;
        --cores)      CORES=${2:?}; shift 2 ;;
        --ram-gb)     RAM_GB=${2:?}; shift 2 ;;
        --disk-gb)    DISK_GB=${2:?}; shift 2 ;;
        --ssh-key)    KEYS+=("${2:?}"); shift 2 ;;
        --guest-user) GUEST_USER=${2:?}; shift 2 ;;
        --port)       PORT=${2:?}; shift 2 ;;
        --stick)      STICK=${2:?}; shift 2 ;;
        --hub)        HUB=${2:?}; shift 2 ;;
        --no-hub)     NO_HUB=true; shift ;;
        --no-egress)  NO_EGRESS=true; shift ;;
        --no-check)   NO_CHECK=true; shift ;;
        --fips)       FIPS=true; shift ;;
        --fips-peer)  FIPS_PEERS+=("${2:?}"); shift 2 ;;
        --restore)    RESTORE=true; shift ;;
        --adopt)      ADOPT=true; shift ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        --wait)       WAIT=${2:?}; shift 2 ;;
        -h|--help)    usage ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$NAME" ] || die "--name is required"
HUB_HOST=${HUB#*@}
$RESTORE || $ADOPT || $VERIFY_ONLY || { [ -n "$CORES" ] && [ -n "$RAM_GB" ] && [ -n "$DISK_GB" ] \
    || die "--cores, --ram-gb and --disk-gb are required"; }
if [ ${#KEYS[@]} -eq 0 ]; then KEYS=("$HOME/.ssh/id_ed25519.pub"); fi

# ---- local key normalisation: literals stay, files are read -----------------
KEYLINES=()
for k in "${KEYS[@]}"; do
    if [[ $k == ssh-* || $k == ecdsa-* || $k == sk-* ]]; then
        KEYLINES+=("$k")
    elif [ -r "$k" ]; then
        while IFS= read -r line; do [ -n "$line" ] && KEYLINES+=("$line"); done < "$k"
    else
        die "not a key and not a readable file: $k"
    fi
done
comment_list=$(printf '%s\n' "${KEYLINES[@]}" | awk '{print $NF}' | paste -sd, -)
printf 'keys: %s\n' "$comment_list"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o ServerAliveInterval=15)

if $VERIFY_ONLY; then
    step "verify only: $NAME (no provisioning)"
else

# ---- 1. make sure the VM host carries the deploy tool ----------------------
step "VM host: $STICK"
if ! ssh "${SSH_OPTS[@]}" "$STICK" 'command -v /usr/local/sbin/kali-live-vm-deploy >/dev/null'; then
    echo "  installing kali-live-vm-deploy on the VM host (not in this image yet)"
    scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$REPO/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-deploy" \
        "$STICK:/tmp/kali-live-vm-deploy"
    ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n install -m 0755 /tmp/kali-live-vm-deploy /usr/local/sbin/kali-live-vm-deploy'
fi
if ! ssh "${SSH_OPTS[@]}" "$STICK" 'command -v /usr/local/sbin/kali-live-vm-fips >/dev/null'; then
    echo "  installing kali-live-vm-fips on the VM host (not in this image yet)"
    scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$REPO/overlay/kali-config/common/includes.chroot/usr/local/sbin/kali-live-vm-fips" \
        "$STICK:/tmp/kali-live-vm-fips"
    ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n install -m 0755 /tmp/kali-live-vm-fips /usr/local/sbin/kali-live-vm-fips'
fi

# ---- 2. keys travel as a file (no quoting games) ---------------------------
KEYFILE=$(mktemp); trap 'rm -f "$KEYFILE"' EXIT
printf '%s\n' "${KEYLINES[@]}" > "$KEYFILE"
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$KEYFILE" "$STICK:/tmp/klh-vm-keys.$$"

REMOTE_ARGS=(--id "$NAME" --guest-user "$GUEST_USER" --ssh-keys-file "/tmp/klh-vm-keys.$$" --wait "$WAIT")
[ -n "$PORT" ] && REMOTE_ARGS+=(--port "$PORT")
if $RESTORE; then REMOTE_ARGS+=(--restore)
elif $ADOPT; then REMOTE_ARGS+=(--adopt)
else REMOTE_ARGS+=(--cores "$CORES" --ram-gb "$RAM_GB" --disk-gb "$DISK_GB"); fi
$NO_EGRESS && REMOTE_ARGS+=(--no-egress)

step "provisioning $NAME on the VM host"
ssh "${SSH_OPTS[@]}" "$STICK" \
    "sudo -n /usr/local/sbin/kali-live-vm-deploy $(printf '%q ' "${REMOTE_ARGS[@]}"); rm -f /tmp/klh-vm-keys.$$" \
    || die "kali-live-vm-deploy failed on $STICK"

STATE=$(ssh "${SSH_OPTS[@]}" "$STICK" "sudo -n cat /run/kali-live-headless/vm-$NAME.env" 2>/dev/null) \
    || die "no state file for $NAME — the deploy did not finish"
fi   # end of the provisioning branch (--verify-only skips it)

# --verify-only reads the state the deploy wrote; a fresh deploy already has it
if [ -z "$STATE" ]; then
    STATE=$(ssh "${SSH_OPTS[@]}" "$STICK" "sudo -n cat /run/kali-live-headless/vm-$NAME.env" 2>/dev/null || true)
fi
[ -n "$STATE" ] || die "no state for $NAME on $STICK (try: ssh $STICK 'sudo cat /mnt/klh-vmstore/vms/$NAME.deploy')"
val() { printf '%s\n' "$STATE" | sed -n "s/^$1=//p" | head -1; }
GUEST_IP=$(val GUEST_IP); EXT_PORT=$(val EXT_PORT); WG_PUB=$(val STICK_WG_PUB); WG_IP=$(val STICK_WG_IP)
[ -n "$GUEST_IP" ] || die "no guest IP in state"
[ -n "$EXT_PORT" ] || EXT_PORT="$PORT"
printf '  guest %s (%s)  external port %s  tunnel %s\n' "$NAME" "$GUEST_IP" "$EXT_PORT" "${WG_IP:-none}"

# ---- 3. concentrator: peer + DNAT unit -------------------------------------
HUB_PUB=""
if $NO_HUB || $VERIFY_ONLY; then
    step "concentrator: skipped"
else
    step "concentrator: $HUB"
    [ -n "$WG_PUB" ] || die "VM host has no WireGuard public key — bring wg0 up first (docs/vm-deploy.md)"
    out=$(ssh "${SSH_OPTS[@]}" "$HUB" "sh -s -- $WG_PUB" < "$HERE/hub-enroll-stick.sh") \
        || die "hub enrollment failed: $out"
    HUB_TUNIP=$(printf '%s\n' "$out" | sed -n 's/.*-> \([0-9.]*\).*/\1/p' | head -1)
    printf '  %s\n' "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    [ -n "$HUB_TUNIP" ] || die "hub did not return a tunnel address"
    ssh "${SSH_OPTS[@]}" "$HUB" "sh -s -- add $NAME $EXT_PORT $HUB_TUNIP $EXT_PORT" < "$HERE/hub-vm-forward.sh" \
        || die "could not publish port $EXT_PORT on the hub"
    HUB_HOST=${HUB#*@}
    HUB_PUB=$(ssh "${SSH_OPTS[@]}" "$HUB" 'curl -sS -m 10 https://ifconfig.me' || true)
    printf '  hub public address: %s\n' "${HUB_PUB:-unknown}"
fi

# ---- 4. verification from this machine -------------------------------------
step "verification"
PASSED=0 FAILED=0
# probe needs a PRIVATE key: --ssh-key may be a .pub path (strip .pub) or a
# literal (then fall back to the agent / default identities).
PROBE_KEY=""
for k in "${KEYS[@]}"; do
    case "$k" in
        ssh-*|ecdsa-*|sk-*) ;;
        *) [ -r "${k%.pub}" ] && { PROBE_KEY="${k%.pub}"; break; } ;;
    esac
done
GUEST_SSH=(-o BatchMode=yes -o StrictHostKeyChecking=no
           -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
[ -n "$PROBE_KEY" ] && GUEST_SSH+=(-i "$PROBE_KEY")

if $NO_HUB; then
    echo "  (no public port: run the isolation checks from the VM host)"
else
    [ -n "$HUB_PUB" ] || HUB_PUB=$(ssh "${SSH_OPTS[@]}" "$HUB" 'curl -sS -m 10 https://ifconfig.me' 2>/dev/null || true)
    probe() { ssh "${GUEST_SSH[@]}" -p "$EXT_PORT" "$GUEST_USER@$HUB_HOST" "$1" 2>/dev/null; }
    # the hub needs a moment after publishing: its DNAT unit starts, the
    # tunnel handshake completes, and the VM host's forward rules reassert.
    # Verifying instantly produced two bogus FAILs on the first real deploy.
    printf '  waiting for %s:%s ' "$HUB_HOST" "$EXT_PORT"
    ready=false
    for _ in $(seq 1 24); do
        if probe 'echo ok' >/dev/null; then ready=true; break; fi
        printf '.'; sleep 5
    done
    printf '\n'
    $ready || echo "  (port not answering yet — checks below will say which part is wrong)"
    if out=$(probe 'echo ok'); then pass "public SSH on $HUB_HOST:$EXT_PORT"; else fail "public SSH on $HUB_HOST:$EXT_PORT"; fi
    egress=$(probe 'curl -sS -m 10 https://ifconfig.me' || true)
    if [ -n "$HUB_PUB" ] && [ "$egress" = "$HUB_PUB" ]; then
        pass "egress leaves via the concentrator ($egress)"
    elif [ -z "$HUB_PUB" ]; then
        printf '  SKIP  egress check (hub public address unknown; guest saw %s)\n' "${egress:-nothing}"
    else
        fail "egress leaves via $egress, expected $HUB_PUB"
    fi
    lan=$(probe 'for t in 192.168.1.1 10.0.0.1; do timeout 2 bash -c "</dev/tcp/$t/22" 2>/dev/null && echo reachable-$t; done; echo done')
    if [ "$lan" = "done" ]; then pass "guest cannot reach RFC1918 hosts"; else fail "guest reached: $lan"; fi
    v6=$(probe 'ip -6 addr show scope global 2>/dev/null | grep -c inet6 || true')
    [ "$v6" = "0" ] && pass "no global IPv6 (no leak path)" || fail "global IPv6 present ($v6)"
    sshd=$(probe 'sudo -n sshd -T 2>/dev/null | awk "/^(passwordauthentication|permitrootlogin)/{print \$2}" | paste -sd, -')
    if [ "$sshd" = "no,no" ]; then pass "sshd: password auth off, root login off"
    else fail "sshd posture: ${sshd:-unknown} (want no,no)"; fi
    # timesyncd needs a few seconds after boot before the clock is marked
    # synchronized — poll instead of sampling once (a fresh --restore failed
    # this instantly on the first try)
    t=""
    for _ in $(seq 1 12); do
        t=$(probe 'timedatectl 2>/dev/null | awk -F": " "/synchronized/{print \$2; exit}"')
        [ "$t" = "yes" ] && break
        sleep 5
    done
    [ "$t" = "yes" ] && pass "clock synchronized" || fail "clock not synchronized (${t:-unknown})"
fi

# ---- 5. checklist -----------------------------------------------------------
# The six checks above gate the deploy; the checklist is the full
# desired-behaviour list (persistence artifacts, cross-VM isolation, resolver
# pinning, authorized keys, port ownership, domain XML lessons). Run it here so
# a deploy ends with a verdict instead of a list of things to go and look at.
if $NO_CHECK; then
    printf '\n== checklist: skipped (--no-check)\n'
else
    step "checklist: tools/vm-check.sh --postflight"
    check_args=(--postflight --name "$NAME" --port "$EXT_PORT"
                --stick "$STICK" --hub "$HUB" --guest-user "$GUEST_USER")
    [ -n "$CORES" ] && check_args+=(--cores "$CORES")
    [ -n "$RAM_GB" ] && check_args+=(--ram-gb "$RAM_GB")
    for k in ${KEYS+"${KEYS[@]}"}; do check_args+=(--expect-key "$k"); done
    if "$HERE/vm-check.sh" "${check_args[@]}"; then
        pass "checklist (vm-check --postflight)"
    else
        fail "checklist (vm-check --postflight) — run it directly to see which property broke"
    fi
fi

# ---- 6. optional per-VM FIPS identity ---------------------------------------
# Modular on purpose: the identity (salt+uuid -> nsec/npub) and the wire
# (daemon in the guest) are separable, exactly like the host's mesh. Without
# --fips-peer the guest holds an identity and no wire — a valid state.
if $FIPS || [ "${#FIPS_PEERS[@]}" -gt 0 ]; then
    step "fips: per-VM mesh identity (kali-live-vm-fips)"
    fargs="install --id $NAME"
    [ -n "$GUEST_USER" ] && fargs="$fargs"          # daemon runs as root in the guest
    for fp in ${FIPS_PEERS+"${FIPS_PEERS[@]}"}; do fargs="$fargs --peer $fp"; done
    # no persistent salt on a toram boot: fall back to a guest-generated key
    # (identity NOT rebuild-stable) rather than failing the deploy
    if ! ssh "${SSH_OPTS[@]}" "$STICK" 'sudo -n test -s /var/lib/kali-live-headless/master.salt'; then
        echo "  no master salt on the host (toram) — guest gets an ephemeral key"
        fargs="$fargs --ephemeral"
    fi
    if out=$(ssh "${SSH_OPTS[@]}" "$STICK" "sudo -n /usr/local/sbin/kali-live-vm-fips $fargs" 2>&1); then
        np=$(printf '%s\n' "$out" | sed -n 's/^npub=//p')
        pass "fips identity installed in the guest${np:+ ($np)}"
    else
        fail "fips install: $(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')"
    fi
fi

# ---- 7. registry (alias <-> uuid <-> npub <-> port) --------------------------
# The map that makes a port change or a rename a one-line operation. Cheap,
# read-only towards guests, always refreshed at the end of a deploy.
if [ -x "$HERE/vm-registry.sh" ]; then
    step "registry"
    if "$HERE/vm-registry.sh" sync --stick "$STICK" >/dev/null 2>&1; then
        "$HERE/vm-registry.sh" list --stick "$STICK" 2>/dev/null | tail -n +3 | sed 's/^/  /'
        pass "registry synced (/mnt/klh-vmstore/registry.tsv)"
    else
        fail "registry sync (tools/vm-registry.sh sync)"
    fi
fi

# ---- 8. hand-off ------------------------------------------------------------
printf '\n'
if $NO_HUB; then
    printf 'guest ready (LAN only):  ssh %s@%s\n' "$GUEST_USER" "$GUEST_IP"
else
    printf 'log in:  ssh -p %s %s@%s\n' "$EXT_PORT" "$GUEST_USER" "$HUB_HOST"
fi
printf 'state:   %s:/run/kali-live-headless/vm-%s.env\n' "$STICK" "$NAME"
printf 'restore: tools/vm-deploy.sh --restore --name %s --stick %s%s\n' "$NAME" "$STICK" \
    "$($NO_HUB && echo ' --no-hub' || true)"
[ "$FAILED" -eq 0 ] || { printf '\n%d check(s) FAILED\n' "$FAILED"; exit 1; }
printf '\nall checks passed (%d)\n' "$PASSED"
