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
