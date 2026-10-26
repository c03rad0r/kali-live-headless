# Private hosted CI on kali-live — spike report (2026-10-26)

**Question** (owner, 2026-10-26): GitHub disabled Actions for
`OpenTollGate/tollgate-module-basic-go` (org-freeze, #790). Can we run a
private hosted CI **deployed on a kali-live boot** — temporary, ephemeral —
to get CI working again for as long as that machine stays up?

**Answer: yes — proven end-to-end, twice, on the live image itself.**

## What was actually proven

A kali-live minimal guest (iso-build31, the currently-flashed image class)
hosted an **ngit-ci coordinator** (the reference Nostr-CI server,
`gitworkshop.dev/danconwaydev/ngit-ci`, MIT) that:

1. discovered a repository purely over Nostr (kind 30617 announcement),
2. was triggered purely over Nostr by a `git push` (kind 30618),
3. ran the repository's `.ngit/act/workflows/demo.yml` in a container via
   the pinned embedded `act`,
4. published a signed kind-9842 Workflow Result that any consumer can
   verify independently of the host that ran it.

Two coordinators ran side by side on the same repository — x280 (commodity
docker) and the kali-live guest — and both attested the same commit:

| coordinator | commit | conclusion | wall | note |
|---|---|---|---|---|
| x280 (`npub1cuj8f4m…`) | c630ef4f | success | 88.5 s | cold (job image pull) |
| x280 | a837c8c9 | success | 7.4 s | warm |
| live guest (`npub14s9uenk…`) | a837c8c9 | **failure** | 195 s | honest red — see defect 2 |
| x280 | 1917dde8 | success | ~7 s | |
| live guest | 1917dde8 | **success** | **6.1 s** | warm, on the live image |

Consumer-side verification (the signed events, not host logs):

```
nak req -k 9842 --tag a=30617:b9e28eb6…:klh-ci-spike-demo wss://relay.ngit.dev
```

The `w` tag of each 9842 carries the workflow path AND its sha256, the `c`
tag the exact commit, `conclusion` the verdict — a run cannot claim to be
of content it did not run.

## Why this is the right shape (and not Gitea/act-from-scratch)

- The tollgate repo **already ships** its CI in ngit/act form:
  `.ngit/act/workflows/` carries 18 ported workflows (test, go-test,
  repro-check, router-test, the 11-shard release pipeline, announce,
  verify-publication). `.ngit/README.md` documents the port and its
  measured constraints. No workflow translation is needed.
- ngit-ci is designed for exactly this: "anyone can run ngit-ci for
  repositories they care about; several coordinators can serve the same
  repository". A stick-hosted instance ADDS capacity/availability next to
  the existing DQ05 coordinator (4 vCPU/4 GiB ceiling) without touching it.
- Triggers and results ride Nostr, so nothing about GitHub's state matters.
  The currently-alive ngit lane (results as fresh as 2026-10-26 15:08Z on
  relay.ngit.dev) keeps working regardless.

## The two defects found on the live image (both fixed in-session)

1. **The live overlay is RAM — docker's data-root must move to a real
   disk.** First attempt filled the root tmpfs (`no space left on device`)
   loading a 325 MB image. Fix: dedicated virtio disk → ext4 →
   `/var/lib/docker` (the vmstore-analog; on a real stick this is the
   KLHCONFIG/vmstore partition). After that, 1.9 GB of job images sat on
   disk and the RAM overlay stayed at ~45 %.
2. **Kali's `docker.io` 28.5.2 breaks act's content copy**: `mkdirat
   var/run/act: path escapes from parent` (strict path validation through
   the /var/run→/run symlink in the job image). docker-ce 29.9.2 from
   download.docker.com (debian trixie repo) runs the identical flow green.
   **Deployment rule: install docker-ce, not docker.io, on the live host.**

## Resource budget (measured)

- Coordinator idle: **~19 MiB RSS, 0.2 % CPU** (5 MiB on x280) — a
  stick can host it all day for free.
- Full stack in a 3.8 GiB guest: 2.4 GiB still available with coordinator
  + docker + cached job images.
- Job image pull is the cold cost (catthehacker/ubuntu:act-latest ≈ 1.9 GB
  on disk; through user-net NAT the first guest job spent ~3 min pulling).
  Warm runs: 6–7 s. **Pre-seed the job images onto the data disk at
  deploy time and every run is warm.**
- The tollgate release lanes are heavier than the demo (OpenWrt SDK images
  ~2–4 GB each, upx minutes of CPU) — the DQ05 numbers in `.ngit/README.md`
  (11.8 min stage-1 warm; one ultra-brute leg 515 s at 2 CPUs) are the
  planning basis. The 20-core/31 GiB machine is ~5× the DQ05 ceiling.

## Deployment recipe (the whole thing, ~10 minutes on a booted stick)

```bash
# 0) on any docker host with network (build once, image is 325 MB / 80 MB gz):
git clone https://relay.ngit.dev/npub15qydau2hjma6ngxkl2cyar74wzyjshvl65za5k5rl69264ar2exs5cyejr/ngit-ci.git
cd ngit-ci && docker build -t ngit-ci-coordinator:latest .
docker save ngit-ci-coordinator:latest | gzip > ngit-ci-image.tar.gz

# 1) on the live boot (SSH'd in): real disk for docker + docker-ce
sudo apt update && sudo apt install -y docker-ce  # via download.docker.com debian repo
sudo mkfs.ext4 -L dockerdata /dev/dX1 && sudo mkdir -p /var/lib/docker \
  && sudo mount /dev/dX1 /var/lib/docker            # vmstore partition
docker load < ngit-ci-image.tar.gz

# 2) coordinator watching the tollgate coordinate
export NGIT_CI_REPOS='npub1nng5mxkdh2mu593twukfr7j3fk5wxfy0v8ujf0e5g8nwwtzlphhqksqpew/tollgate-module-basic-go'
export NGIT_CI_EXECUTION_POLICY='automatic'   # operator choice; see below
export DOCKER_GROUP_ID=$(stat -c %g /var/run/docker.sock)
docker compose -f docker-compose.host-socket.yml up -d --no-build
```

From that moment, every push the maintainer mirrors to
`relay.ngit.dev` gets CI — compile, tests, packaging, the works —
attested under the stick coordinator's key. Boot another stick tomorrow,
repeat 1–2, and it is back.

## Owner decisions (not technical blockers)

- **Which coordinate to watch.** The demo watched a throwaway repo. Watching
  the real tollgate coordinate is the one-line change above; it means our
  instance also runs on maintainer mirror pushes (duplicate-but-additive
  attestations; consumers pick keys they trust). Policy alternative:
  keep `request-required` and have a maintainer send one kind-9843 naming
  our coordinator.
- **Secrets for release lanes.** `NSEC_HEX` (Blossom/Nostr publish) is
  provisioned operator-side in `ngit-ci-secrets.env`
  (`NGIT_CI_SECRET_<ALIAS>__NSEC_HEX`). The historical release key is
  unrecoverable from GitHub (write-only); the DQ05 deployment already runs
  a dedicated CI key (`6cfc53c0…`) — reuse it or mint another.
- **The 9843 gate / approval posture.** `automatic` runs anything seen;
  `request-required` waits for a maintainer's standing Service Request.

## Honest limits

- PR *refs* get CI when they are mirrored to the nostr repo (the trigger
  script supports arbitrary refs); GitHub PRs themselves are not nostr PRs.
- The release stage-2 shards and announce are driven (by design) via
  `scripts/ngit-ci-release.sh` + maintainer-signed 9840s — a stick
  coordinator runs them when triggered, it does not remove the driver.
- Ephemeral means ephemeral: the coordinator's signing key lives in the
  `coordinator-data` volume — put that volume on the data disk too, or the
  stick's coordinator identity rotates every boot (results remain valid;
  only key continuity is lost).
- act runs GitHub-compatible workflows, not GitHub: `.ngit/README.md`
  documents exactly what the port already worked around (no cross-file
  `needs:`, no dynamic matrix, no `container:` blocks, artifacts travel
  over Blossom).

## Artifacts

- Spike workspace: `/tmp/opencode/klh-ci-spike/` (scripts, logs, demo repo).
- Live demo repo: `https://gitworkshop.dev/npub1h83gadn…/relay.ngit.dev/klh-ci-spike-demo`
- x280 coordinator: left running (`ngit-ci-coordinator-1`, watching the
  demo coordinate, ~5 MiB) — `sudo docker compose -p ngit-ci down` to stop.

## Appendix: `up-coordinator.sh`

```bash
#!/usr/bin/env bash
# Start the ngit-ci coordinator (host-socket variant) watching the demo repo.
# Spike: 2026-10-26 — private CI on commodity docker, target: kali-live stick.
set -euo pipefail
cd "$(dirname "$0")/ngit-ci"
export NGIT_CI_REPOS='npub1h83gadn7kurs5d6ewlj00z8ce9s7d5uqy0njc6gzew37ducytlaq9yxfxh/klh-ci-spike-demo'
export NGIT_CI_EXECUTION_POLICY='automatic'   # we are the operator; no 9843 gate for the spike
export NGIT_CI_MAX_CONCURRENT_JOBS='2'
export DOCKER_GROUP_ID="$(stat -c %g /var/run/docker.sock)"
exec sudo -E docker compose -f docker-compose.host-socket.yml up -d
```

## Appendix: `fire-trigger.sh`

```bash
#!/usr/bin/env bash
# Push a new commit to the demo repo = the push trigger (kind 30618) the
# coordinator is waiting for. Prints the commit sha for the result watcher.
set -euo pipefail
cd "$(dirname "$0")/demo-repo"
export PATH="$(dirname "$0")/bin:$PATH"
echo "spike trigger $(date -u +%FT%TZ)" >> README.md
git add README.md
git -c user.name=spike -c user.email=spike@localhost commit -qm "trigger: $(date -u +%H%M%S)"
git push ngit main 2>&1 | tail -3
echo "TRIGGER_COMMIT=$(git rev-parse HEAD)"
```

## Appendix: `watch-results.sh`

```bash
#!/usr/bin/env bash
# Watch for CI results (kinds 9841/9842/39842) for the demo repo on the relays.
# Usage: watch-results.sh [commit-sha]
set -uo pipefail
cd "$(dirname "$0")"
COMMIT=${1:-}
NPUB_HEX=b9e28eb67eb7070a375977e4f788f8c961e6d38023e72c6902cba3e6f3045ffa
FILTER="-k 9842 -k 9841 -k 39842 --tag a=30617:${NPUB_HEX}:klh-ci-spike-demo"
[ -n "$COMMIT" ] && FILTER="$FILTER -c $COMMIT"
timeout 120 ./bin/nak req $FILTER wss://relay.ngit.dev 2>/dev/null | while IFS= read -r ev; do
  kind=$(printf '%s' "$ev" | jq -r .kind)
  when=$(printf '%s' "$ev" | jq -r '.created_at | todate')
  case $kind in
    9842) concl=$(printf '%s' "$ev" | jq -r '[.tags[]|select(.[0]=="s" or .[0]=="status")][0][1] // "?"')
          wf=$(printf '%s' "$ev" | jq -r '[.tags[]|select(.[0]=="w")][0][1] // "?"')
          echo "[$when] WORKFLOW RESULT: $wf -> ${concl^^}" ;;
    9841) job=$(printf '%s' "$ev" | jq -r '[.tags[]|select(.[0]=="j")][0][1] // "?"')
          concl=$(printf '%s' "$ev" | jq -r '[.tags[]|select(.[0]=="s" or .[0]=="status")][0][1] // "?"')
          echo "[$when]   job $job: $concl" ;;
    39842) step=$(printf '%s' "$ev" | jq -r '.content' | head -c 100)
          echo "[$when]   progress: $step" ;;
  esac
done
echo "(watch window ended)"
```

## Appendix: `guest-setup.sh`

```bash
#!/usr/bin/env bash
# In-guest (kali-live minimal) setup v2: docker with data-root on the dedicated
# virtio disk (vmstore-analog), image streamed in (never stored in RAM-overlay).
set -euo pipefail
echo "[$(date -u +%T)] guest: $(uname -r)"
# 1. docker packages
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose >/dev/null
sudo apt-get clean
# 2. dedicated disk -> /var/lib/docker (the live overlay is RAM; this is the store)
DISK=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v '^/dev/sr' | while read -r d; do [ "$(lsblk -bdnpo SIZE "$d")" -gt 10000000000 ] && echo "$d" && break; done)
[ -n "$DISK" ] || { echo "FATAL: no dedicated data disk found"; exit 1; }
echo "data disk: $DISK ($(lsblk -bdnpo SIZE "$DISK" | numfmt --to=iec))"
sudo systemctl stop docker docker.socket 2>/dev/null || true
echo -e 'g\nn\n\n\n\nw\n' | sudo fdisk "$DISK" >/dev/null 2>&1 || true
sudo mkfs.ext4 -q -F -L dockerdata "${DISK}1"
sudo mkdir -p /var/lib/docker
sudo mount "${DISK}1" /var/lib/docker
grep -q dockerdata /etc/fstab || echo "LABEL=dockerdata /var/lib/docker ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
# 3. daemon up + data-root confirmed
sudo systemctl start docker
sudo docker info --format 'data-root: {{.DockerRootDir}}  driver: {{.Driver}}'
# 4. stream-load the coordinator image (no copy in guest fs)
sudo docker load
sudo docker images --format '{{.Repository}} {{.Size}}'
echo "[$(date -u +%T)] docker ready: $(sudo docker version --format '{{.Server.Version}}')"
```

## Appendix: `guest-up-coordinator.sh`

```bash
#!/usr/bin/env bash
# In-guest: start the ngit-ci coordinator from the preloaded image.
# Mirrors the x280 instance but on the kali-live system itself.
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE='sudo -E docker compose'
sudo -E docker compose version >/dev/null 2>&1 || COMPOSE='sudo -E docker-compose'
export NGIT_CI_REPOS='npub1h83gadn7kurs5d6ewlj00z8ce9s7d5uqy0njc6gzew37ducytlaq9yxfxh/klh-ci-spike-demo'
export NGIT_CI_EXECUTION_POLICY='automatic'
export NGIT_CI_MAX_CONCURRENT_JOBS='1'
export DOCKER_GROUP_ID="$(stat -c %g /var/run/docker.sock)"
$COMPOSE -p ngit-ci -f docker-compose.host-socket.yml up -d --no-build
sleep 5
sudo docker logs ngit-ci-coordinator-1 2>&1 | grep -E 'identity|Watching|Connected|baseline' | head -6
echo "GUEST_COORDINATOR_UP $(date -u +%T)"
```
