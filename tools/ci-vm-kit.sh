#!/usr/bin/env bash
# ci-vm-kit.sh — stand up the private CI VM on a kali-live-headless stick.
#
# Architecture (the VM is the isolation boundary):
#
#   laptop ──ssh──> live stick (kali-live, KVM host, kvm-firewall posture)
#                    └─ KVM CI VM (this kit) ─ egress pinned into wg0 →
#                         ├─ docker-ce 29.x
#                         ├─ ngit-ci coordinator (triggers + results over
#                         │   Nostr — no inbound port needed anywhere)
#                         └─ act job containers (arbitrary CI code stays
#                             inside the VM; exits the world via inr2)
#
# Subcommands:
#   bundle  DIR                 assemble the deploy bundle (image tar +
#                               payload + compose + env template + base
#                               cloud image so the stick never downloads)
#   ram-store STICK SIZE_GB     volatile store: tmpfs at /mnt/klh-vmstore
#                               (RAM-only boots; no deployer changes needed)
#   deploy  STICK NAME C:R:D    create the VM (thin passthrough to
#                               tools/vm-deploy.sh --no-hub: no public port,
#                               egress via the tunnel by default)
#   install STICK NAME DIR ENV  push bundle + env into the VM, run payload
#   verify  STICK NAME          coordinator facts from inside the VM
#
# Examples:
#   tools/ci-vm-kit.sh bundle /tmp/ci-bundle
#   tools/ci-vm-kit.sh ram-store kali@kali-live.local 10
#   tools/ci-vm-kit.sh deploy  kali@kali-live.local ci 8:24:30
#   tools/ci-vm-kit.sh install kali@kali-live.local ci /tmp/ci-bundle ./ci-vm.env
#   tools/ci-vm-kit.sh verify  kali@kali-live.local ci
#
# Exit codes: 0 ok, 1 failure, 2 usage.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=15 -o ServerAliveInterval=15)
BASE_IMAGE_URL=${KLH_CI_BASE_IMAGE:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}
COORD_IMAGE=${KLH_CI_COORD_IMAGE:-/tmp/opencode/klh-ci-spike/ngit-ci-image.tar.gz}

die() { printf 'ci-vm-kit: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
cmd=${1:-}; [ -n "$cmd" ] && shift || usage

# --- bundle ------------------------------------------------------------------
bundle() {
    local dir=${1:?bundle dir}
    mkdir -p "$dir"
    [ -r "$COORD_IMAGE" ] \
        || die "coordinator image not found at $COORD_IMAGE (build it per docs/private-ci-ngit-spike-2026-10-26.md, or set KLH_CI_COORD_IMAGE)"
    cp -f "$COORD_IMAGE" "$dir/ngit-ci-image.tar.gz"
    cp -f "$HERE/ci-vm-payload.sh" "$HERE/ci-vm-compose.yml" "$HERE/ci-vm.env.example" "$dir/"
    local img
    img="$dir/$(basename "$BASE_IMAGE_URL")"
    if [ ! -s "$img" ]; then
        echo "  downloading base cloud image (once, ~350 MB) ..."
        curl -fsSL --retry 3 -o "$img.part" "$BASE_IMAGE_URL" || die "base image download failed"
        mv "$img.part" "$img"
    fi
    printf 'bundle at %s:\n' "$dir"
    du -h "$dir"/* | sed 's/^/  /'
    printf 'next: edit %s/ci-vm.env.example -> ci-vm.env, then deploy + install\n' "$dir"
}

# --- ram-store ---------------------------------------------------------------
# Volatile profile: a tmpfs at the store mountpoint. The deployer, the pool,
# the volumes and the seeds all land in RAM and vanish at poweroff. SIZE caps
# the store so a runaway job gets ENOSPC inside the VM instead of OOMing the
# live host. Guest RAM + store blocks BOTH come out of host RAM — see the
# budget table in docs/ci-vm-runbook.md before choosing sizes.
ram_store() {
    local stick=${1:?stick} size=${2:?size GB}
    ssh "${SSHO[@]}" "$stick" "set -e
        if findmnt -rn /mnt/klh-vmstore >/dev/null; then
            findmnt -rn /mnt/klh-vmstore | awk '{print \"already mounted: \" \$1 \" (\" \$3 \")\"; exit}'
            exit 0
        fi
        sudo -n mkdir -p /mnt/klh-vmstore
        sudo -n mount -t tmpfs -o size=${size}g tmpfs /mnt/klh-vmstore
        sudo -n mkdir -p /mnt/klh-vmstore/vms
        sudo -n virsh -c qemu:///system pool-info klh-vmstore >/dev/null 2>&1 \
            || sudo -n virsh -c qemu:///system pool-start klh-vmstore >/dev/null 2>&1 \
            || sudo -n virsh -c qemu:///system pool-define-as klh-vmstore dir --target /mnt/klh-vmstore >/dev/null
        sudo -n virsh -c qemu:///system pool-start klh-vmstore >/dev/null 2>&1 || true
        findmnt -rn /mnt/klh-vmstore | awk '{print \"volatile store: \" \$1 \" \" \$3}'
        free -h | awk 'NR==2{print \"host RAM after: \" \$7 \" avail\"}'"
}

# --- deploy ------------------------------------------------------------------
# cores:ram:disk, e.g. 8:24:30. --no-hub keeps the VM dark (no public SSH
# port); egress via wg0 is the deployer's default and needs no hub round-trip.
deploy() {
    local stick=${1:?stick} name=${2:?name} spec=${3:?cores:ram-gb:disk-gb}
    local cores ram disk
    IFS=: read -r cores ram disk <<<"$spec"
    "$REPO/tools/vm-deploy.sh" --name "$name" --cores "$cores" --ram-gb "$ram" \
        --disk-gb "$disk" --stick "$stick" --no-hub
}

# --- install -----------------------------------------------------------------
install_ci() {
    local stick=${1:?stick} name=${2:?name} dir=${3:?bundle dir} env=${4:?env file}
    [ -r "$env" ] || die "env file not readable: $env"
    local remote_dir=/tmp/ci-kit-$$
    echo "== pushing bundle to the stick"
    scp -q "${SSHO[@]}" "$dir/ngit-ci-image.tar.gz" "$dir/ci-vm-payload.sh" \
        "$dir/ci-vm-compose.yml" "$env" "$stick:$remote_dir/" 2>/dev/null \
        || { ssh "${SSHO[@]}" "$stick" "mkdir -p $remote_dir"; \
             scp -q "${SSHO[@]}" "$dir/ngit-ci-image.tar.gz" "$dir/ci-vm-payload.sh" \
                "$dir/ci-vm-compose.yml" "$env" "$stick:$remote_dir/"; }
    [ -r "$dir/ngit-ci-secrets.env" ] \
        && scp -q "${SSHO[@]}" "$dir/ngit-ci-secrets.env" "$stick:$remote_dir/" || true
    echo "== installing inside the VM (via the stick; a few minutes)"
    ssh "${SSHO[@]}" "$stick" "set -e
        state=/run/kali-live-headless/vm-$name.env
        [ -r \"\$state\" ] || { echo 'no state file \$state — deploy first' >&2; exit 1; }
        . \"\$state\"
        echo \"VM at \${GUEST_IP:-unknown}\"
        sudo -n ssh -i /var/lib/kali-live-headless/vmhost-ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            \"\${GUEST_USER:-debian}@\$(sed -n 's/^GUEST_IP=//p' \$state)\" \
            'mkdir -p /tmp/ci && chmod 700 /tmp/ci'
        sudo -n scp -q -i /var/lib/kali-live-headless/vmhost-ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            $remote_dir/ngit-ci-image.tar.gz $remote_dir/ci-vm-payload.sh \
            $remote_dir/ci-vm-compose.yml $remote_dir/$(basename "$env") \
            \"\${GUEST_USER:-debian}@\$(sed -n 's/^GUEST_IP=//p' \$state):/tmp/ci/\"
        [ -f $remote_dir/ngit-ci-secrets.env ] && sudo -n scp -q -i /var/lib/kali-live-headless/vmhost-ed25519 \
            -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            $remote_dir/ngit-ci-secrets.env \"\${GUEST_USER:-debian}@\$(sed -n 's/^GUEST_IP=//p' \$state):/tmp/ci/\"
        sudo -n ssh -i /var/lib/kali-live-headless/vmhost-ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            \"\${GUEST_USER:-debian}@\$(sed -n 's/^GUEST_IP=//p' \$state)\" \
            'cd /tmp/ci && { [ -f ci-vm.env ] || mv $(basename "$env") ci-vm.env; } && chmod 600 ci-vm.env && bash ci-vm-payload.sh'
        rm -rf $remote_dir"
}

# --- verify ------------------------------------------------------------------
verify() {
    local stick=${1:?stick} name=${2:?name}
    ssh "${SSHO[@]}" "$stick" "set -e
        state=/run/kali-live-headless/vm-$name.env
        [ -r \"\$state\" ] || { echo 'no state file' >&2; exit 1; }
        ip=\$(sed -n 's/^GUEST_IP=//p' \$state)
        echo '== coordinator (inside the VM):'
        sudo -n ssh -i /var/lib/kali-live-headless/vmhost-ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \${GUEST_USER:-debian}@\$ip \
            'sudo docker logs ngit-ci-coordinator-1 2>&1 | grep -E \"identity|Watching|Connected|baseline\" | tail -5
             echo \"egress: \$(curl -sS -m 8 https://ifconfig.me 2>/dev/null || echo unknown)\"
             sudo docker stats --no-stream --format \"coordinator: {{.MemUsage}}\"'"
}

case "$cmd" in
    bundle)   bundle "$@" ;;
    ram-store) ram_store "$@" ;;
    deploy)   deploy "$@" ;;
    install)  install_ci "$@" ;;
    verify)   verify "$@" ;;
    *)        usage ;;
esac
