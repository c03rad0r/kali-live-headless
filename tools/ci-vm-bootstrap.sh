#!/usr/bin/env bash
# ci-vm-bootstrap.sh — rebuild the CI-VM deploy bundle ON a kali-live boot.
#
# For the day you boot a real stick on real hardware with nothing but
# internet: this reconstructs what the lane pre-built on the dev laptop
# (docs/private-ci-ngit-spike-2026-10-26.md), entirely from public sources,
# then hands off to tools/ci-vm-kit.sh.
#
# Run ON the live stick, from a clone of the lane/ci-vm-hosting branch:
#
#   git clone -b lane/ci-vm-hosting \
#       https://github.com/Amperstrand/kali-live-headless.git
#   cd kali-live-headless && tools/ci-vm-bootstrap.sh ~/ci-lab
#
# What it does (all in RAM unless you point WORKDIR at real disk):
#   1. docker-ce on the live host (TEMPORARY bootstrap-only; the CI VM
#      carries its own daemon afterwards),
#   2. builds the ngit-ci coordinator image from source,
#   3. pulls the act job image from docker.io (NOT ghcr: its CDN stalls
#      behind double-NAT — runbook lesson #2) and retags to the ghcr name,
#   4. assembles the bundle via ci-vm-kit.sh (base cloud image included),
#   5. mints a coordinator nsec (identity continuity across reboots) and
#      writes ci-vm.env watching the DEMO coordinate — one line to swap in
#      the real tollgate coordinate when you are ready to arm it.
#
# Exit codes: 0 ok, 1 failure, 2 usage.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKDIR=${1:?usage: ci-vm-bootstrap.sh <workdir>}
BUNDLE="$WORKDIR/bundle"
NGIT_CI_REPO=https://relay.ngit.dev/npub15qydau2hjma6ngxkl2cyar74wzyjshvl65za5k5rl69264ar2exs5cyejr/ngit-ci.git
DEMO_REPO_COORD='npub1h83gadn7kurs5d6ewlj00z8ce9s7d5uqy0njc6gzew37ducytlaq9yxfxh/klh-ci-spike-demo'

say()  { printf '\n== %s\n' "$1"; }
die()  { printf 'ci-vm-bootstrap: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as the live user (kali), not root"
sudo -n true 2>/dev/null || die "passwordless sudo required on the live image"

mkdir -p "$WORKDIR" "$BUNDLE"

# --- 1. docker-ce on the live host (bootstrap-only; spike-proven recipe) -----
say "docker-ce on the live host (RAM overlay; bootstrap-only)"
if ! sudo docker version --format '{{.Server.Version}}' 2>/dev/null | grep -qE '^(29|3[0-9])\.'; then
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -r /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg -o "$WORKDIR/docker.gpg"
        sudo cp "$WORKDIR/docker.gpg" /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    fi
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce >/dev/null
    sudo systemctl enable --now docker
fi
echo "docker: $(sudo docker version --format '{{.Server.Version}}')"

# --- 2. coordinator image from source ----------------------------------------
say "building ngit-ci coordinator image (~10-20 min on many cores)"
if [ ! -s "$BUNDLE/ngit-ci-image.tar.gz" ]; then
    [ -d "$WORKDIR/ngit-ci" ] || git clone -q "$NGIT_CI_REPO" "$WORKDIR/ngit-ci"
    sudo docker build -q -t ngit-ci-coordinator:latest "$WORKDIR/ngit-ci" >/dev/null
    sudo docker save ngit-ci-coordinator:latest | gzip > "$BUNDLE/ngit-ci-image.tar.gz"
fi
du -h "$BUNDLE/ngit-ci-image.tar.gz"

# --- 3. job image via docker.io (ghcr CDN stalls behind NATs) ----------------
say "act job image via docker.io + retag to the ghcr name"
if ! sudo docker image inspect ghcr.io/catthehacker/ubuntu:act-latest >/dev/null 2>&1; then
    sudo docker pull -q catthehacker/ubuntu:act-latest >/dev/null
    sudo docker tag catthehacker/ubuntu:act-latest ghcr.io/catthehacker/ubuntu:act-latest
fi
if [ ! -s "$BUNDLE/act-job-image.tar.gz" ]; then
    sudo docker save ghcr.io/catthehacker/ubuntu:act-latest | gzip > "$BUNDLE/act-job-image.tar.gz"
fi
du -h "$BUNDLE/act-job-image.tar.gz"

# --- 4. assemble the bundle (adds payload, compose, env template, base OS) ---
say "assembling the bundle"
KLH_CI_COORD_IMAGE="$BUNDLE/ngit-ci-image.tar.gz" \
KLH_CI_JOB_IMAGE="$BUNDLE/act-job-image.tar.gz" \
    "$HERE/ci-vm-kit.sh" bundle "$BUNDLE"

# --- 5. coordinator nsec + env (demo coordinate; swap when arming tollgate) --
say "minting the coordinator nsec and writing ci-vm.env"
if [ ! -s "$WORKDIR/coordinator.nsec" ]; then
    nak_bin="$WORKDIR/nak"
    [ -x "$nak_bin" ] || { curl -fsSL -o "$nak_bin" \
        https://github.com/fiatjaf/nak/releases/download/v0.16.2/nak-v0.16.2-linux-amd64 && chmod +x "$nak_bin"; }
    hex=$("$nak_bin" key generate 2>/dev/null)
    nsec=$(python3 - "$hex" <<'PY'
import sys
CHARSET='qpzry9x8gf2tvdw0s3jn54khce6mua7l'
def polymod(v):
    G=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; c=1
    for x in v:
        b=c>>25; c=(c&0x1ffffff)<<5^x
        for i in range(5): c^=G[i] if ((b>>i)&1) else 0
    return c
def hrp(h): return [ord(x)>>5 for x in h]+[0]+[ord(x)&31 for x in h]
def cb(d,f,t):
    a=0;b=0;r=[];m=(1<<t)-1
    for v in d:
        a=(a<<f)|v;b+=f
        while b>=t: b-=t;r.append((a>>b)&m)
    if b: r.append((a<<(t-b))&m)
    return r
d=cb(bytes.fromhex(sys.argv[1]),8,5);h=hrp('nsec')+d
c=polymod(h+[0]*6)^1
print('nsec1'+''.join(CHARSET[x] for x in d+[(c>>25)&31,(c>>20)&31,(c>>15)&31,(c>>10)&31,(c>>5)&31,c&31]))
PY
    )
    umask 077; printf '%s\n' "$nsec" > "$WORKDIR/coordinator.nsec"
fi
NPUB_HEX=$(python3 - "$WORKDIR/coordinator.nsec" <<'PY'
import sys
CHARSET='qpzry9x8gf2tvdw0s3jn54khce6mua7l'
def polymod(v):
    G=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; c=1
    for x in v:
        b=c>>25; c=(c&0x1ffffff)<<5^x
        for i in range(5): c^=G[i] if ((b>>i)&1) else 0
    return c
s=open(sys.argv[1]).read().strip(); p=s.rfind('1'); hrp=s[:p]
d=[CHARSET.index(ch) for ch in s[p+1:]]
assert polymod([ord(x)>>5 for x in hrp]+[0]+[ord(x)&31 for x in hrp]+d)==1
d=d[:-6]; a=0;b=0;r=[]
for v in d:
    a=(a<<5)|v;b+=5
    while b>=8: b-=8;r.append((a>>b)&255)
print(bytes(r).hex())
PY
)
sed -e "s|^NGIT_CI_REPOS=.*|NGIT_CI_REPOS='$DEMO_REPO_COORD'|" \
    -e "s|^NGIT_CI_MAX_CONCURRENT_JOBS=.*|NGIT_CI_MAX_CONCURRENT_JOBS='2'|" \
    -e "s|^# NGIT_CI_COORDINATOR_NSEC=.*|NGIT_CI_COORDINATOR_NSEC=$(cat "$WORKDIR/coordinator.nsec")|" \
    "$HERE/ci-vm.env.example" > "$BUNDLE/ci-vm.env"
chmod 600 "$BUNDLE/ci-vm.env"

say "bootstrap complete"
echo "coordinator pubkey (record it — this identity attests your CI):"
echo "  hex  : $NPUB_HEX"
echo "  bundle: $BUNDLE"
echo
echo "next (diskless 32G profile; for other profiles see docs/ci-vm-runbook.md):"
echo "  tools/ci-vm-kit.sh ram-store \$USER@localhost 12   # from the laptop — OR on-stick:"
echo "  sudo mount -t tmpfs -o size=12g tmpfs /mnt/klh-vmstore && sudo mkdir -p /mnt/klh-vmstore/vms"
echo "  tools/ci-vm-kit.sh deploy  \$STICK ci 8:16:30"
echo "  tools/ci-vm-kit.sh install \$STICK ci $BUNDLE $BUNDLE/ci-vm.env"
echo "  tools/ci-vm-kit.sh verify  \$STICK ci"
echo
echo "ARMING TOLLGATE (owner call): swap NGIT_CI_REPOS in ci-vm.env to"
echo "  npub1nng5mxkdh2mu593twukfr7j3fk5wxfy0v8ujf0e5g8nwwtzlphhqksqpew/tollgate-module-basic-go"
echo "and re-run install (the coordinator restarts watching the real coordinate)."
