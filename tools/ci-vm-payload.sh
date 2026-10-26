#!/usr/bin/env bash
# ci-vm-payload.sh — install the ngit-ci coordinator INSIDE a CI VM.
#
# Runs in the guest deployed by tools/vm-deploy.sh (Debian cloud image,
# user with passwordless sudo). Everything CI-related lives inside this VM:
# docker-ce, the coordinator container, and every job container act spawns.
# The VM is the isolation boundary — CI code never runs on the live host.
#
# Spiked and proven 2026-10-26 (docs/private-ci-ngit-spike-2026-10-26.md):
#   - docker-ce (>=29) is REQUIRED: Debian's docker.io 28.5 rejects act's
#     content copy with "mkdirat var/run/act: path escapes from parent".
#   - image arrives prebuilt (80 MB gz) so the VM never compiles Rust.
#
# Inputs (cwd): ngit-ci-image.tar.gz, ci-vm-compose.yml, ci-vm.env
# Env: CI_PRESEED_IMAGES (default: the act job image; "none" to skip)
set -euo pipefail
cd "$(dirname "$0")"
echo "[ci-payload] $(date -u +%T) guest: $(uname -m), $(free -h | awk 'NR==2{print $7}') avail"

for f in ngit-ci-image.tar.gz ci-vm-compose.yml ci-vm.env; do
    [ -r "$f" ] || { echo "FATAL: missing $f in $(pwd)" >&2; exit 1; }
done
chmod 600 ci-vm.env   # may carry NGIT_CI_COORDINATOR_NSEC / repo secrets

# --- docker-ce (skip if a new-enough daemon is already there) ---------------
need_docker=true
if sudo docker version --format '{{.Server.Version}}' 2>/dev/null | grep -qE '^(29|3[0-9])\.'; then
    need_docker=false
    echo "[ci-payload] docker $(sudo docker version --format '{{.Server.Version}}') already >= 29"
fi
if $need_docker; then
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -r /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.gpg
        sudo cp /tmp/docker.gpg /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    fi
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce >/dev/null
    sudo systemctl enable --now docker
    sudo apt-get clean
fi
echo "[ci-payload] docker daemon: $(sudo docker version --format '{{.Server.Version}}')"

# --- coordinator from the prebuilt image ------------------------------------
sudo docker load < ngit-ci-image.tar.gz
# --- bring it up (as root: the install dir and env live under /root) --------
sudo mkdir -p /root/ngit-ci
sudo cp ci-vm-compose.yml /root/ngit-ci/docker-compose.host-socket.yml
sudo cp ci-vm.env /root/ngit-ci/ci-vm.env && sudo chmod 600 /root/ngit-ci/ci-vm.env
sudo chmod 644 /root/ngit-ci/docker-compose.host-socket.yml

# --- per-repo secrets file is optional (NGIT_CI_SECRET_<ALIAS>__<NAME>) -----
if [ -r ngit-ci-secrets.env ]; then
    sudo cp ngit-ci-secrets.env /root/ngit-ci/ngit-ci-secrets.env
    sudo chmod 600 /root/ngit-ci/ngit-ci-secrets.env
    echo "[ci-payload] per-repo secrets file installed (never printed)"
fi

# --- bring it up (root: the install dir + env live under /root, mode 600) ----
sudo bash -e -c '
    cd /root/ngit-ci
    set -a; . ./ci-vm.env; set +a
    DOCKER_GROUP_ID="$(stat -c %g /var/run/docker.sock)"
    export DOCKER_GROUP_ID
    docker compose -p ngit-ci -f docker-compose.host-socket.yml up -d --no-build
'
sleep 5

# --- job image: deterministic, from the bundle — never a first-boot pull -----
# (measured 2026-10-26: ghcr's CDN stalls behind double-NAT on first contact;
#  docker.io works but is slow; a bundle-carried image is instant and offline)
if [ -r act-job-image.tar.gz ]; then
    echo "[ci-payload] loading job image from the bundle ..."
    sudo docker load < act-job-image.tar.gz >/dev/null \
        || echo "[ci-payload] WARNING: bundle image load failed"
elif [ "${CI_PRESEED_IMAGES:-none}" != none ]; then
    echo "[ci-payload] pre-pulling job image (no bundle copy; first job may pay a slow pull) ..."
    sudo docker pull -q "${CI_PRESEED_IMAGES}" >/dev/null \
        || echo "[ci-payload] WARNING: pre-pull failed; first job pays the pull cost"
fi

# --- facts -------------------------------------------------------------------
echo "[ci-payload] coordinator:"
sudo docker logs ngit-ci-coordinator-1 2>&1 \
    | grep -E 'Coordinator identity|Watching repository|Connected to' | head -5
echo "[ci-payload] egress from this VM: $(curl -sS -m 8 https://ifconfig.me 2>/dev/null || echo unknown)"
echo "[ci-payload] DONE $(date -u +%T)"
