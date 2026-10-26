# AGENTS.md — kali-live-headless

Operational truth for agents working this repo. The README covers what the
project *is*; this file covers how to work on it safely and what to watch.

## Architecture rule (the one that matters)

This repo is a **thin overlay on the official upstream**
(`gitlab.com/kalilinux/build-scripts/kali-live`, pinned `KALI_LIVE_REF` in
`lib/common.sh`). Never vendor, copy, or commit upstream trees or personal
live-build forks — every neighbor project that did (`prateepb`,
`andrew-stclair`, `ISO-of-doom-2022`) is dead from exactly that. Upstream
drift is absorbed by bumping the pin, nothing else.

## Watch list (check when touching builds / bumping the pin)

1. **`KALI_LIVE_REF` pin** — deliberate bumps only, on rebuild days. After a
   bump the suite must re-prove: Stage B (ISO content, bootloader timeouts),
   one BIOS menu boot to SSH, and the forensic + KLHCONFIG-override stages.
2. **Kali live-config components** we interoperate with:
   `1165-fix-openssh-server` (their password flip — our `0000-` drop-in must
   keep sorting first) and `0031-kali-user-setup` (user creation from
   `/etc/skel` — our authorized_keys path depends on it). If upstream renames
   or rewrites these, the README's "why the drop-in survives" section and the
   suite assertions need updating with fresh evidence.
3. **Bootloader generation**: upstream's `isolinux.cfg`/grub config could
   change shape; our overlay *replaces* the isolinux file and *appends to*
   grub's `config.cfg`. Stage B asserts both — a change upstream shows up as
   a Stage B failure, not a silent unattended-boot regression.
4. **live-build hook conventions** (`.hook.chroot` suffix, `hooks/live/`
   directory) — the genre's classic breakage (see ISO-of-doom's post-mortem
   on hook paths). Verify after pin bumps.
5. **Kali rolling churn**: NetworkManager/wpa_supplicant behavior (the
   watchdog's nmcli TYPE-string lesson: `connection show --active` says
   `802-11-wireless`, `device status` says `wifi`), firmware packages,
   `kali-linux-default` metapackage contents (ISO size drift). Two more
   proven cases (2026-10-21, first full BIOS run): OpenSSH ≥ 10 prints
   `sshd -T` keys **CamelCase** (`PermitRootLogin`) where older prints
   lowercase — normalize case before exact-match greps; and newer
   NetworkManager dropped `connection.id` from `nmcli -g` fields — use
   `-g NAME`. Guest assertions must tolerate both old and new output.
   Third case (2026-10-23, vm-store M1): `mount -t fuseblk -o uid=...`
   dies on the new mount API (`fsconfig(): fuseblk: Unknown parameter
   'uid'`) — FUSE option-bearing mounts must go through the helper
   (`mount -t ntfs-3g`), which routes options to the userspace driver;
   /proc/mounts still reports `fuseblk`. Fourth case (2026-10-22,
   firewall session): **iptables normalizes its own output** — inserted
   `-i virbr0 -d CIDR` dumps as `-d CIDR -i virbr0`, and
   `--ctstate ESTABLISHED,RELATED` dumps as `RELATED,ESTABLISHED`.
   Fixed-string parses of command output are a recurring defect class:
   match order- and case-insensitively, always. `tools/firewall-lab.sh`
   doubles as the fixture for the iptables ones.
6. **QEMU suite environment**: `-cdrom` vs virtio-blk boot quirks are
   firmware-dependent (SeaBIOS refuses virtio firmware-boot of this ISO);
   re-verify stage layout if QEMU/SeaBIOS/OVMF updates change behavior.
   The suite's hostfwd port is `KLH_TEST_PORT` (default 2222) — **agents in
   parallel worktrees must pick their own port** (e.g. `KLH_TEST_PORT=2225`)
   instead of killing whoever holds 2222: that listener may be another
   lane's legitimate suite run (2026-10-23: one was killed under the
   "stale listener" rule; it wasn't stale, it was p4M's).
7. **`tools/iso-hotpatch.sh` carries five hard-won guards** (docker `-i`
   artifact check, mksquashfs `-noappend`, hook-equivalent modes incl.
   sudoers 0440, `-boot_image any replay` or the remux drops El Torito,
   `--no-owner --no-group` + `-all-root` or the worktree's uid-1000 leaks
   onto image dirs and sudo dies). Never bypass them; always boot-gate a
   hotpatched build (`./test.sh --stage bios`) before flashing — three
   defective #13s were caught exactly there, and each lesson is asserted by
   the tool now. It also recreates hook-owned unit enablement symlinks —
   extend that list when adding units the chroot hook enables.
9. **Never trust `grep -c` on a log a live process is still writing** (hit twice on 2026-10-24: a promotion was counted 0 while the same grep's print showed it — output flush races the count): read-back and print the line, or wait for process exit, before deriving counts from live logs.
10. **Verdict capture: use `tools/run-logged.sh`, never
   `echo "...rc=$?"` with a `$(date)` in the same string** — the command
   substitution runs first and resets `$?`; chains have recorded rc=0
   for FAILING runs TWICE (2026-10-22 CHAIN-STATUS, 2026-10-23
   watch-16-17.log). The wrapper captures rc on the next line and
   stamps correctly; the only real verdicts are `output/test-run*.log`
   RESULT lines.
11. **`tools/firewall-lab.sh` gates firewall changes** (30 s, docker):
   runs the REAL kvm-firewall daemon + vm-forward in a NET_ADMIN
   container at 1-second ticks and asserts the four hard-won
   invariants (drops install; sanctioned exceptions tolerated — no
   reassert race; libvirt-jump shadowing self-heals; INPUT shield is
   STATEFUL). Run it after ANY edit to `kali-live-kvm-firewall` /
   `kali-live-vm-forward` — the QEMU boot stages cannot see these
   interplay bugs (they don't exercise host→guest flows, and take ~40
   min each). Note its two negative controls: `docker run -i` (without
   it the heredoc never arrives and the lab false-passes) and the
   output-presence check (no `lab: pass=` line = transport bug, not a
   pass). Both earned their keep within minutes of writing the tool.
12. **Count-zero verdicts need non-empty-list proof** (three hits in
   one night): `grep -c` on an EMPTY file returns 0 — a "must be absent"
   assert passes vacuously if the extraction failed, the path was wrong
   (#19's minimal ISO has a different filename!), or the transport died.
   Assert list-length sanity BEFORE reporting any count-based verdict;
   the count is part of the assertion. Same class: a green test count
   you didn't verify belongs to the named suite (the rescue-publish
   Dockerfile ran ws-relay's suite — 6 tests where 5 were expected).
13. **The staged build tree persists BETWEEN builds and `cp -a` never
   deletes** — an untracked file staged once rides every subsequent
   build with its original mtime (the #18/#19 wedge drop-in: git-clean
   trees, three-week-old mtime inside fresh images, fingerprint
   `2026-10-01 21:21`). The provenance guard (build.sh, upstream ∪
   overlay allowed-set — mind the upstream-native whitelist, first live
   run false-positived grub.cfg) refuses such builds; never bypass it,
   and cut releases from merged main, not from a lane's dirty worktree.
14. **A test that remediates before it asserts masks boot-path
   defects**: hw-check's wait-loop used to `virsh net-start` the
   default network itself, so the #14 kvm-enable early-exit (no virbr0
   at boot on real hardware, QEMU suite 182/0 green) was invisible in
   hardware runs too. hw-check now asserts "virbr0 up without help"
   BEFORE remediating — keep that ordering, and apply the pattern:
   *verify the product did X, then fix X for downstream tests*.
8. **dd-ing an ISO onto a stick restores the ISO's own partition table** —
   any partition appended afterwards (KLHCONFIG!) is orphaned even though
   its sectors survive past the image. flash.sh detects and reuses a
   surviving labeled partition (7ff7ef5); before that, every flash
   silently dropped the stick's identities. Related: never write to a
   device on a live stick without first matching it against the device
   backing `/run/live/medium`.
9. **Orphaned build clients burn CPU silently** (found 2026-10-22): when the
   tmux that drives a build dies, the root-owned
   `sudo -E build-in-container.sh → sudo → docker run` chain can survive with
   no container behind it and spin ~1.4 cores each forever (three chains from
   2026-10-21 had burned ~1.3 CPU-days and were masking as "slow builds").
   Before blaming a slow build, compare
   `ps -eo user,pid,ppid,etime,pcpu,cmd | grep -E "build-in-container|docker run"`
   with `sudo docker ps` — a client with no container is a zombie; kill the
   whole chain. Related: the suite's SSH forward is 127.0.0.1:2222, so a leaked
   QEMU (deleted pidfile = `test.sh` cleanup can't find it) makes all four boot
   stages FAIL on port bind after ~40 min of waiting; check
   `ss -ltnp | grep 2222` before starting the suite.

## Build discipline (hard-won)

- Builds run inside **tmux** with plain `> file 2>&1` redirect — never a
  pane-level `| tee` (pipe backpressure wedged three builds; see README
  "Rebuilding / long runs").
- **Never edit a script while one of its runs is in flight — `build.sh`,
  `test.sh`, `flash.sh`, `lib/`, or anything under `tools/`**: bash reads
  incrementally, and a 4h build or a 16-min `dd` gives it a huge window to
  resume at a stale byte offset in the *new* file. Build #8 (2026-10-21)
  exited rc=1 *after a successful 4h build* because the wrapper was edited
  mid-run; 2026-10-22 the same thing hit a user's flash: the edit landed
  during `dd`, and when it finished the run died with a bogus syntax error —
  silently skipping verification and the KLHCONFIG partition. flash.sh now
  self-detects a mid-run edit (stamp check after the write) and tells the
  operator to finish with `--verify-only`.
- A build needs ≥30G free under the repo; `output/` holds multi-GB ISOs —
  preserve known-good ones under `output/iso-build<N>/` before a risky build.
- Secrets: `./config` holds the Wi-Fi PSK in plaintext **by design** (see
  README threat model). It is git-ignored; staged copies are scrubbed by the
  EXIT trap unless `--keep-secrets`. Never print, log, or commit it.
- Testing an **old ISO**: use the matching harness revision in a throwaway
  `git worktree` (e.g. `git worktree add --detach <dir> <ref>` + copy
  `./config` in, run `./test.sh --iso <path>`). HEAD's suite asserts HEAD's
  features and will false-fail against older images.
- **Verdict capture**: `echo "[$(date)] rc=$?"` always prints `rc=0` — the
  command substitution runs first and resets `$?`. Capture the rc into a
  variable on the line *after* the command, before any substitution. (Chains
  5/7/8 did this wrong: `output/CHAIN-STATUS` records rc=0 for suites whose log
  says `RESULT: FAIL`, and chain5's checksum gate ran `sha512sum -c` from the
  repo root instead of `output/`, reporting a bogus ISO failure. The file is
  annotated; `output/test-run*.log` is the only real verdict.)
- **ISO artifacts**: never commit ISO bytes (gitignored by design — each image
  bakes the PSK, host keys and console password; the repo is public). Version
  them by *provenance* instead: every build gets a row in `BUILDS.md` (build
  number, repo commit, `KALI_LIVE_REF`, KVM on/off, suite verdict, sha512) and
  a self-describing archive at `output/iso-build<N>/` with `BUILD-MANIFEST.txt`,
  `INDEX.md` and `SHA256SUMS`. Always validate with an explicit
  `--iso output/iso-build<N>/...` — the bare `output/*.iso` slot is overwritten
  by the next build. Retention: latest green + one KVM-less fallback + any
  image holding unique defect evidence.
- **One build at a time per output dir**: the slot path is shared, so starting
  build N+1 while N's ISO is still wanted silently destroys N. Preserve first,
  then build.

## Improvements backlog (2026-10-25 update; ranked by leverage)

- **Build-time budget & cache layers (where the ~2h20m minimal build goes)**:
  xz squashfs ~55m · debootstrap+chroot install ~45-70m (cold every time —
  upstream stage [1/4] wipes chroot/, cache/, config/) · package download
  ~5-15m · initrd/xorriso/verify ~15m. **Correction 2026-10-26: the warm apt
  cache claimed here never worked.** `hooks/build/klh-apt-cache.hook.build`
  used a `*.hook.build` suffix that live-build does not execute at all (it
  scans only `config/hooks/{normal,live}/*.chroot`); build #33 logged no hook
  output and left `.klh-apt-cache` empty, and the symlink is wiped by
  upstream's stage-1 `cleanup_fs` regardless. Hook + build.sh block removed
  rather than left looking functional (AGENTS #16 class). Walked back —
  warm caching now belongs to a URL-keyed HTTP cache outside the tree
  (`squid-deb-proxy` :8000, auto-detected upstream; apt-cacher-ng stays banned
  by the 2026-10-22 wrong-bytes postmortem). See docs/reproducible-builds.md.
  On a 20-core box downloads are ~half of a 10-minute build, so this is now
  the top speed lever, ahead of zstd. Still open, in order:
  1. **HTTP cache on :8000** (replaces the dead lb-cache attempt above).
  2. **hot-chroot lane** — preserve chroot/ across builds (skip debootstrap
     for iteration builds; upstream's unconditional wipe means this needs
     either an upstream flag or our own `lb build` invocation on a preserved
     tree — MUST stay a separate experimental path; release builds stay
     cold-clean, provenance guard unchanged).
  3. **parallel boot gates** — LANDED 2026-10-25 (`tools/suite-parallel.sh`,
     jobs=3 default): halves post-build gate wall-clock; watch CPU on 8-core
     hosts (2×4-vcpu guests is the ceiling).
- **zstd squashfs experiment** — the hotpatch's ~55 min is nearly all
  xz recompression (full builds pay the same tax in their squashfs
  phase). The kernel has supported zstd squashfs for years and
  decompresses it as fast or faster. Recipe: one build with the
  compressor switched, boot-gate BIOS+UEFI, compare `time mksquashfs`.
  If green: hotpatch ~10 min, builds ~40 min shorter. Highest-leverage
  single experiment available.
- ~~**split test/stages/stage-cde.sh**~~ — LANDED externally (0266acf),
  which is also how Stage F got dropped: RUN_VMSTORE parsed, nothing
  consumed it, `--stage vmstore` passed vacuously. Restored as
  test/stages/stage-f-vmstore.sh + wired into suite-parallel's default
  list (2026-10-26, vm-store-m1 lane). LESSON: every stage split must
  diff the RUN_* flag set against the modules that consume it — a parsed
  flag with no consumer IS a vacuous pass.
- ~~**Parallel boot stages**~~ — LANDED 2026-10-25: `tools/suite-parallel.sh`
  (see the build-time budget entry above).
- **Mechanical verdict ledger** — test.sh should emit a machine-readable
  verdict line that `iso-archive.sh`/BUILDS.md rows consume; several
  rows were hand-typed and one chain lied (item 10). The ledger is only
  as trustworthy as its least-typed row.
- **Auto-pick `KLH_TEST_PORT`** (free ephemeral port + lock dir) instead
  of a fixed default — eliminates the cross-lane "kill the stale
  listener" incident class rather than documenting it.
- **Mesh end-to-end campaign** — stick identity, enrollment, hub
  handshake are proven; actual FIPS mesh traffic (rendezvous, peer
  round-trip, socat forwards into a VM) is the last unproven README
  claim. Lives in the private overlay's lane.

15. **The image's SSH rate limiter LATCHES** (2026-10-26, three victims in
   one day: the operator's ssh loop, the QEMU suite, the hardware battery):
   `iptables -m recent --update` refreshes the window on every match, so ONE
   connection over threshold seals the source and every retry re-seals it.
   Threshold is now 7/min; ANY repeat client of a stick (suite, hw-check,
   scripts) must use ControlMaster multiplexing — one connection, immune.
16. **Mode gates silently disable features**: `[ -x file ]` guards that fail
   on a 100644 file shipped the feature dead with zero errors —
   derive_identity.py was non-executable from v19 through v28, so the wg
   salt-derivation NEVER ran and every key ever issued was the random
   fallback (found 2026-10-26 via `sh -x` on a live guest). Stage-b now
   asserts every runtime-gated executable bit; keep that list current when
   adding `-x` guards.
17. **sudo's HOME is /root** (2026-10-26): anything user-homed (the stick
   registry!) resolved under sudo must go through SUDO_USER's passwd entry;
   flash.sh's registry hook silently used root's empty registry otherwise.
18. **Settle semantics**: a boot-stage's asserts must wait for a COMPLETION
   sentinel (provision's `/run/kali-live-headless.settled`, its literal last
   line), never for proxies — the banner file isn't ordered after provision,
   and the blackbox dir appeared before its final stable activation; both
   fired mid-provision and the asserts read a half-built machine twice.
19. **`lsblk` lacks `-o END` on some hosts** — `/sys/block/<disk>/<part>/start`
   + `/size` is the portable partition-end source (two scripts burned by
   this on 2026-10-26).
20. **A slow dd is a diagnosis** (2026-10-26): a flash writing at ~6 MB/s
   failed verification — USB2 port or bad cable; flash.sh now warns on
   <15 MB/s before the verify wastes minutes.
21. **A live stick with no synced clock hard-fails apt and TLS** (2026-10-26,
   v31 `apt update` on hardware): apt's **sqv** verifier (unlike gpgv)
   REFUSES signatures whose creation time is in the guest's future —
   `sqv: Not live until 2026-10-26T06:21:15Z` can be (a) upstream signer
   clock skew (transient: the sig goes live minutes later — **retry, never
   `[trusted=yes]`**), or (b) the stick's own clock behind reality (dead
   RTC battery on live boots). Fix shipped: systemd-timesyncd in every
   package list + enabled by the chroot hook + FallbackNTP drop-in +
   KLHCONFIG `NTP_SERVERS=` override + a BOUNDED sync-wait in provision
   before the settled marker; suite asserts active+synced. Same root cause
   class as TLS not-yet-valid failures.
22. **A q35 guest with no video device hangs in BIOS/option-ROM init**
   (2026-10-26, `kali-live-vm-deploy`): `virt-install --graphics none` alone
   omits `<video>`, and the guest then loops in SeaBIOS/option ROM — GRUB
   prints `Booting 'Debian GNU/Linux'`, the machine resets, one core stays
   busy, the serial console is silent, no DHCP lease appears, and the vCPU
   sits in 32-bit code with `EDX=0xcf8` (PCI config port). `--video vga`
   (no listener) fixes it. Corollary: an *identical* domain definition boots
   or not depending on this, so "the disk boots under plain QEMU" does not
   clear libvirt — compare `virsh domxml-to-native qemu-argv` (and the
   `-cpu` line) between a working and a broken guest first.
23. **`--cpu host` triple-faults on this hybrid-Intel host** (2026-10-26,
   second confirmation): it resolves to `mode=custom match=exact check=full`
   and the guest resets before the kernel prints. Use a named model with
   `check='none'` (`Skylake-Client` is proven); `--cpu max` is accepted at
   define time and refused at start (`Unknown CPU model max`). Note
   `virt-install` may add `ibpb/md-clear/spec-ctrl/ssbd` features to a
   `--cpu MODEL,check=none` request; the deploy strips them so the request
   stays the bare model.
24. **A WireGuard hub DNAT must target the *stick's* forwarded port**, not the
   guest's service port: `22023 -> 10.66.x.y:22023`, and the stick's
   `kali-live-vm-forward` then DNATs to the guest's 22. Targeting `:22` looks
   right and times out. `tools/hub-vm-forward.sh` also owns the port it
   publishes (it deletes any stale DNAT rule for that port first — the first
   matching rule wins, and a re-publish after a tunnel re-address otherwise
   silently keeps the old destination).
25. **`kali-live-vm-rm --stale` must never sweep a provisioned guest**
   (2026-10-26): the first cut removed every volume whose domain was not
   RUNNING, so a deliberate `virsh destroy` — or a concurrent suite run
   sweeping the host mid-debug — deleted a live test guest's disk. The sweep
   now skips any volume with a defined domain or a `.deploy`/`.xml` sidecar;
   those go only via explicit `--id NAME`.
26. **`sudo`'s `secure_path` has no `/usr/local/sbin`**: shipped tools calling
   each other must use absolute paths, and guest-side asserts needing root
   (`sshd -T`) must use `sudo -n` — otherwise the check silently reads
   nothing and reports a false FAIL.
27. **Multi-line key lists word-split into garbage**: `for k in $KEYS` splits
   `ssh-ed25519 AAAA... comment` into three "keys" and rejects all of them.
   Read keys one per LINE (`IFS='\n'`), and remember a `.pub` path is not a
   private key — probe with the stripped path.

28. **Guest egress reaches the CONCENTRATOR's cloud metadata** (2026-10-26,
   found by `tools/vm-check.sh` on its first run): a guest's
   `http://169.254.169.254/` is NAT'd at the hub, so the reply is the hub's own
   cloud metadata service (`hetzner/v1` — instance metadata, which can carry
   user-data and secrets), not a dead link-local address. Link-local must never
   leave a guest: `-i virbr0 -d 169.254.0.0/16 -j DROP` is now part of
   `kali-live-kvm-firewall`'s invariants (and added immediately by
   `kali-live-vm-deploy`'s egress step). The lesson generalizes: an egress
   tunnel moves the *location* of every special-use address, so assert
   reachability of the metadata/link-local/loopback surface from inside a
   guest, never from the host.
29. **`while read` drops the LAST line of an unterminated list**: `read`
   returns non-zero at EOF even when it filled the variable, so
   `while read -r x; do` silently skips the final entry — `post.ssh.keys`
   reported a key "missing" that was present (2026-10-26). Always
   `while IFS= read -r x || [ -n "$x" ]; do`. Same family as #27: parsing a
   multi-entry list is where checks lie.
30. **`tools/vm-check.sh` is the VM desired-behaviour checklist** (preflight +
    postflight, `--json`, exit 1 on any FAIL; the id → property table is
    `docs/vm-checklist.md`). `tools/vm-deploy.sh` runs the postflight
    automatically at the end of every deploy. When you fix a VM-hosting defect,
    add the check that would have caught it — this is the regression suite for
    properties the QEMU boot stages cannot see (egress, isolation, resolver
    pinning, persistence artifacts, port ownership). Its find on day one:
    guests could read the concentrator's cloud metadata (item 28).

31. **Hostnames are hardware-derived by default** (`HOSTNAME_SCHEME=hardware`,
   2026-10-26): the provisioner names each boot after the machine
   (`<model>-<cores>c<ram>r<disk>d`, e.g. `x280-8c16r256d`) via
   `kali-live-hostname-derive`; `kali-live-hostname-settle.service` probes
   mDNS once the LAN is up and appends `-2`/`-3` for identical machines
   (dash, never `_` — underscore is illegal in hostnames and the image's
   own `valid_hostname()` rejects it). Consequences to keep in mind:
   `HOSTNAME` in `./config` is now only the static-mode name and the
   derivation fallback; `scripts/stick-conf.sh` MUST NOT emit a `HOSTNAME=`
   line for the hardware scheme (that line is the boot-time override and
   would pin every stick to the build name — asserted in Stage A);
   `hw-check.sh` needs `--host` in hardware mode; probes are best-effort
   (no route in 30 s or no mDNS resolver = no disambiguation; simultaneous
   first boots are re-probed twice after avahi's collision resolution, but
   a LAN that never answers mDNS can still leave both on the base name).
   avahi registers our own name with 127.0.0.1/::1, fe80:: and site-local
   fec0:: too, so the duplicate probe must count EVERY own address including
   loopback — filtering lo or non-global scopes made every boot suffix `-2`.
   Test hooks `KLH_DMI_DIR`/`KLH_SYSBLOCK`/`KLH_MEMINFO`/`KLH_NPROC`/
   `KLH_PROBE_CMD`/`KLH_OWN_ADDRS` exist for fixture-based unit tests.

## Public-repo hygiene

The repo is **public**. Nothing private may land here, ever: no PSKs, SSIDs,
BSSIDs (geolocatable — one was scrubbed + history-rewritten 2026-10-21;
pre-rewrite bundle: `~/backups/kali-live-headless-pre-rewrite-20261021.bundle`),
LAN IPs, host keys, private SSH keys. The **stick registry**
(`~/.local/share/kali-live-headless/stick-registry.tsv`) holds every stick's
master salt: it lives OUTSIDE the repo on purpose — never copy, commit, or
print its contents (tools print digests only). Before any push that adds
docs or diagnostics, grep the diff for MAC patterns
(`([0-9a-f]{2}:){5}[0-9a-f]{2}`) and private IP ranges. History rewrites
require a fresh bundle in `~/backups/` first and a force-push to origin.

## Pre-commit gate (`.githooks/pre-commit`)

Enable once per clone — it is a hook, not a CI-only convention:

```sh
git config core.hooksPath .githooks      # then every commit runs it
.githooks/pre-commit --all               # or check the whole tree on demand
```

What it enforces, and why each rule exists:

| rule | reason |
|---|---|
| shell syntax (`bash -n` / `sh -n`) | a wrapper edited mid-run once died at a stale byte offset |
| shellcheck, warning+ | the recurring quoting/parsing defect class (#5, #26, #27, #29) |
| no public IPv4 / MAC / private key / token | the repo is PUBLIC; addresses here are geolocatable or ours |
| no literal `./config` secret values | compares without ever printing the value |
| no ISO / disk-image bytes | images bake the PSK, host keys and console password |
| exec bit on shipped shell files | AGENTS.md #16 — a 100644 file under an `-x` guard ships the feature dead |
| trailing whitespace / CRLF / 2 MiB cap / final newline | noise that hides real diffs |

Escape hatches, both requiring a reason on the same line: `leak-ok: <why>` for a
legitimate public address (documented resolvers, examples) and `nocover: <why>`
for shellcheck context it cannot see. Bypassing with `--no-verify` is a last
resort and should be named in the commit message.

The hook is also a *repair* tool: run `--all` before a release. Its first run
found a 100644 `kali-live-blackbox` (masked only by a build-time `chmod`), a
9.9 MB binary being text-scanned, and four whitespace/quoting defects.

## Collaboration

Collaborators with write: `c03rad0r`, `felixfelix-bot`. No license by choice
(2026-10-21 decision — packaging of the official live-build process; genre
norm; revisit if outside contributors appear). Cross-repo lane state lives in
`~/src/ops/workspace-state.md` — keep the kali-live-headless section current
when the lane changes state.
