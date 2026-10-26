# CI VM hosting runbook — private CI inside KVM on a live stick (2026-10-26)

Continuation of `docs/private-ci-ngit-spike-2026-10-26.md` (the proof).
This is the deployment shape for real use: **the CI lives inside a KVM
guest on the live stick**, so arbitrary CI pipelines run behind a real
hypervisor boundary, and all of their traffic exits the world through
`inr2.cashu.exchange`.

```
laptop ──ssh──> live stick (KVM host, kvm-firewall posture)
                 └─ CI VM (Debian 13, deployed by kali-live-vm-deploy)
                     ├─ docker-ce 29.x            (NOT docker.io — spike lesson)
                     ├─ ngit-ci coordinator       (triggers + signed results
                     │                              ride Nostr; no inbound port)
                     └─ act job containers        (the untrusted code; never
                                                    touches the live host)
                 egress: guest subnet policy-routed into wg0 → inr2
```

## Your RAM questions, answered with numbers

Everything on a live boot is RAM unless it lands on a real partition. A
volatile CI VM therefore costs **guest RAM + every disk block it writes**
(they are tmpfs pages on the host):

| component | RAM cost | note |
|---|---|---|
| live host (minimal + KVM stack) | ~1.5 GB | measured on #31-class boots |
| CI VM guest RAM (`--ram-gb`) | as sized | OS+docker resident ~1 GB of it |
| CI VM disk blocks (volatile store) | only blocks written | base image ~1.5 GB + catthehacker job image ~1.9 GB + SDK images 2–4 GB each (release lanes only) |
| coordinator idle | ~20 MiB | negligible |

**32 GB machine (20c/31G): yes, diskless is fine.** Sizing that works:
`ram-store 12` + `deploy ci 8:16:30` → 1.5 + 16 + ≤12 ≈ 29.5 GB worst case,
and the store cap turns overruns into ENOSPC *inside the VM* (a red job),
never a host OOM. That runs the fast lanes (test / go-test / repro-check /
compile) trivially and the SDK/apk release lanes serially. The only cost of
diskless: **every boot re-pulls the job images** (~2 GB for the fast set,
~8–10 GB if you pre-seed SDK lanes too) — through inr2 that is bandwidth
nobody counts, but it is 10–20 minutes of first-run latency. The new
machine's plaintext C: (rw-proven, `klh-write-test.txt`) can hold the store
whenever you decide you want warm boots; nothing else changes.

**16 GB machine (15 Gi): RAM-only works for the fast lanes, not the release
matrix.** Budget: 1.5 host + 8 VM RAM + ~4 volatile store = 13.5 GB — that
is the ceiling, and it fits catthehacker + Go compiles comfortably, but NOT
three OpenWrt SDK images plus their build trees at once. Two honest options:
(a) fast-lane profile in RAM (`ram-store 4` + `deploy ci 4:8:20`, one job at
a time) and run release lanes on the 32G box; (b) give it a real store —
that box's C: is BitLocker-encrypted, and disk mode is still gated on the
pending owner actions from the vm-store lane (the `powercfg /h off` +
VMSTORE-partition decision recorded in workspace-state). There is no third
option where 15 Gi of RAM holds a 17-leg SDK matrix — that is physics, not
config.

**Docker inside the KVM guest: yes, by design.** The payload installs
docker-ce *in the VM*; the coordinator and every job container are siblings
inside that VM. CI code would need: a container escape (docker → VM kernel),
then a VM escape (KVM → live host kernel), and even then it sits behind the
live host's kvm-firewall posture (guest↛LAN drops, stateful INPUT shield,
link-local/metadata drop — AGENTS #28). Its only route to the internet is
the tunnel: `kali-live-vm-deploy` policy-routes the guest subnet into `wg0`
by default, so `curl ifconfig.me` inside any job answers with **inr2's
address**, not the stick's or the site's. That egress posture is asserted by
the deployer's own in-guest check and by `tools/vm-check.sh --postflight`.

## Deploy, end to end (when the machine is back)

On the laptop (this repo):

```sh
tools/ci-vm-kit.sh bundle /tmp/ci-bundle          # image tar + payload +
                                                  # compose + env + base qcow2
cp tools/ci-vm.env.example /tmp/ci-bundle/ci-vm.env
$EDITOR /tmp/ci-bundle/ci-vm.env                  # repos, policy, nsec, caps
```

On the stick (over ssh, `STICK=kali@<stick>`), pick a profile:

```sh
# diskless (either machine — see budget table for sizes):
tools/ci-vm-kit.sh ram-store $STICK 12            # 32G box; use 4 on the 16G box
# with a real store partition present, skip ram-store entirely.

tools/ci-vm-kit.sh deploy  $STICK ci 8:16:30      # cores:ramGB:diskGB
tools/ci-vm-kit.sh install $STICK ci /tmp/ci-bundle /tmp/ci-bundle/ci-vm.env
tools/ci-vm-kit.sh verify  $STICK ci              # identity, watching, egress IP
```

First boot takes ~6–10 min (cloud-init + docker-ce install + pre-pull).
Then push something to the watched mirror — or `scripts/ngit-ci-trigger.sh`
— and read the verdict:

```sh
nak req -k 9842 --tag a=30617:<repo-npub-hex>:<repo-id> wss://relay.ngit.dev
```

## Identity continuity (recommended)

Without config, the coordinator mints a fresh Nostr key at every boot —
results stay valid, but consumers see a new attester each time. Generate
once, keep it in the env file (and your vault):

```sh
nak key generate   # hex → nsec, see the spike doc's recipe
# → NGIT_CI_COORDINATOR_NSEC=... in ci-vm.env (file is mode 600)
```

Every ephemeral boot then re-uses the same coordinator identity. For the
release lanes' `NSEC_HEX` (Blossom/Nostr publish), use
`ngit-ci-secrets.env` next to the env file — the DQ05 CI key (`6cfc53c0…`)
is the one already announcing, or mint a stick CI key of your own.

## What runs here (and what still needs the maintainers)

- Anything the watched repos declare under `.ngit/act/workflows/` — for
  tollgate that is the full ported suite including the sharded release
  pipeline, driven by `scripts/ngit-ci-release.sh` (maintainer-signed 9840s)
  exactly as on DQ05. Multiple coordinators serving one repo is the designed
  state; ours adds capacity, it does not disturb DQ05's.
- Arbitrary GitHub-syntax pipelines for repos *without* an ngit port: ssh
  into the VM and run `act -W .github/workflows/<file>.yml` directly — same
  isolation, manual trigger. (A Gitea-actions runner inside the same VM is
  the natural next step if that becomes routine.)
- Not covered: GitHub PR refs (only mirrored refs trigger), and secrets
  reach only maintainer-authored triggers by protocol design.

## Machine profiles (summary)

| profile | store | deploy spec | jobs | lanes |
|---|---|---|---|---|
| 32G diskless | `ram-store 12` | `8:16:30` | 2 | fast + release (serial SDK) |
| 32G with C: store | real store | `12:24:40` | 2–4 | everything, warm boots |
| 16G diskless | `ram-store 4` | `4:8:20` | 1 | fast lanes only |
| 16G with store (owner actions pending) | real store | `6:10:30` | 1–2 | fast + serial SDK |

## Rehearsal evidence (2026-10-26, x280 nested-KVM lab)

The full stack was rehearsed by booting iso-build31 under QEMU (nested KVM
enabled) and driving the kit against it. Proven, with logs:

| layer | verdict | evidence |
|---|---|---|
| private-CI loop, end to end | **PROVEN** (signed 9842s on relay.ngit.dev) | spike doc: 3 commits, 2 coordinators, warm run 6.1 s |
| coordinator on a live boot (docker in RAM overlay + data-root on disk) | **PROVEN** | spike leg 2: run green 6.1 s, identity npub14s9uenk… |
| nested KVM on the live image | **PROVEN** | /dev/kvm present in the live guest, kvm-firewall active |
| repo deployer provisions the CI VM inside the live guest | **PROVEN** | deploy green on core checks (13/19 postflight PASS; fails were hub-absence artifacts) |
| docker-ce + coordinator running INSIDE the CI VM | **PROVEN** | identity npub1kx95g5… logged, watching the demo repo |
| store persistence across a live reboot | **PROVEN** (by accident) | live reboot mid-rehearsal: ci.* artifacts intact, `--restore` path exercised |
| act job completing INSIDE the nested VM | **PROVEN** (2026-10-26 ai-legion pass) | commit 6456d302: conclusion `success`, 2.1 s, dual-attested on relay.ngit.dev (`fdab25ca` nested + `c72474d7` x280) |

The one open row closed on the second rehearsal host (ai-legion, 20c/31G,
7.8G free after other lanes' services): the same stack with the bundle-
carried job image completed the triggered act job inside the nested VM in
**2.1 s** (vs the 15G x280 lab, which had hit its RAM ceiling — that box
was the blocker, never the design). Two more lessons from that pass:

8. **QEMU 8.2 (Ubuntu) hangs the live guest at boot without an explicit
   `-vga std`** — the no-video BIOS/option-ROM hang class (AGENTS #22),
   resurfacing on raw QEMU where `-display none` alone did not keep a
   usable video device on that build. Symptom: 0-byte serial, no DHCP,
   ~5% vCPU. Always pass `-vga std` with `-display none`.
9. **Drive the stack through a ProxyJump alias when the runner host's key
   isn't the baked one** — the live guest only authorizes the build-time
   key, so a lab on another host drives it via
   `ProxyJump <lab-host>` in ~/.ssh/config rather than key surgery on the
   guest.

### Lessons baked into the kit by the rehearsal

1. **Never place rehearsal/host artifacts on tmpfs** — a 20G store qcow2 on
   a 7.8G tmpfs produced EIO storms → ext4 journal damage → silently lost
   VM files. Real disk for anything that grows; `mkfs` after any EIO.
2. **ghcr.io pulls stall behind double-NAT** (manifest OK, layers at 0 B/s
   for 15+ min) while docker.io pulls fine — so the bundle now carries the
   job image and the payload loads it locally; a first-boot registry pull is
   a fallback, not the path.
3. **A wedged pull holds the layer lock**: `docker load` of the same image
   hangs behind it. `systemctl restart docker` clears it (coordinator
   auto-resumes via restart policy).
4. **The deploy-time GUEST_IP goes stale** (fresh cloud-init re-leases;
   observed .144 → .104). The kit resolves the live lease via
   `virsh domifaddr` and only falls back to the state file.
5. **vm-deploy's rapid fresh SSH connections trip the image's latching
   rate limiter** (AGENTS #15): give the stick a ControlMaster alias in
   ~/.ssh/config before driving the kit against it.
6. **The store marker needs its full key set** (`KLH_VMSTORE_POOL` etc.) or
   `kali-live-vm-create` dies under `set -u` — on real sticks the
   vmstore-mount service writes it; the marker shim is rehearsal-only.
7. **`vm-deploy.sh` died at the FIPS tail whenever `--fips` was omitted**
   (unset array + `${#arr[@]:-0}` = bad substitution) — fixed on this lane.

## First boot on a real machine — what to expect

The whole flow is: `bundle` (laptop, once) → on the stick: `ram-store` (if
diskless) → `deploy` → `install` → `verify`. First `install` takes ~4–8 min
(docker-ce install + image loads). Then push to the watched mirror (or
`scripts/ngit-ci-trigger.sh`) and read the 9842. Expect the coordinator's
identity line in `verify` output; persist it via `NGIT_CI_COORDINATOR_NSEC`
in the env file for cross-boot identity continuity.
