# (end Stage C/D/E)

QEMU_BIN=qemu-system-x86_64
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  record skip "qemu" "qemu-system-x86_64 not installed"
elif [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  record skip "qemu" "no ISO"
elif [ "$RUN_QEMU" != true ]; then
  record skip "qemu" "disabled via --skip-qemu"
else
  if [ -w /dev/kvm ]; then ACCEL=kvm; CPU=(-cpu host); BOOT_TIMEOUT=480; CD_BOOT_TIMEOUT=2400; else ACCEL=tcg; CPU=(); BOOT_TIMEOUT=1800; CD_BOOT_TIMEOUT=4800; klh_warn "no /dev/kvm — using TCG emulation (slow)"; fi
  # Parallel gates (tools/suite-parallel.sh) export KLH_BOOT_SCALE: 3-4
  # concurrent guests stretch userspace boot well past the serial budgets
  # (the 2026-10-26 gate: override's DHCP completed AFTER its 480s direct-
  # kernel budget ran out — guest fully healthy at the login prompt).
  if [ -n "${KLH_BOOT_SCALE:-}" ]; then
    BOOT_TIMEOUT=$(( BOOT_TIMEOUT * KLH_BOOT_SCALE ))
    CD_BOOT_TIMEOUT=$(( CD_BOOT_TIMEOUT * KLH_BOOT_SCALE ))
  fi
  record pass "qemu accel" "$ACCEL"
  klh_info "CD-ROM boots (BIOS/UEFI) allow ${CD_BOOT_TIMEOUT}s: the ISO's ~226MB initrd crawls over emulated ATAPI; direct-kernel boots (override/forensic) get ${BOOT_TIMEOUT}s"

  # Preflight: every boot stage below forwards host 127.0.0.1:$PORT to the
  # guest's sshd. A QEMU left over from an interrupted run still holds the
  # port (its pidfile may already be gone), and then every stage burns a full
  # timeout and reports a misleading "did not boot to SSH" FAIL — 2026-10-22
  # lost 40 min of BIOS wait plus three more stages that way. Reap pidfile
  # leftovers, then refuse to start if the port is still taken.
  PORT_OK=true
  # Deterministic SMBIOS for every guest: default QEMU ships EMPTY DMI
  # fields, machine_fingerprint() raises, and derive_identity silently
  # failed in EVERY prior suite run — wg fell back to random and the old
  # "wg0 up" assert passed vacuously (found in the 2026-10-26 v26 gate:
  # KEYSOURCE=random despite a valid fixture salt; no assert could see it
  # until the unification checks). A fixed uuid/serial pair also makes the
  # fixture-salt identities STABLE and precomputable per guest.
  KLH_SMBIOS=(-smbios "type=1,uuid=4b4c482d-5145-4d55-4944-303130323334" \
               -smbios "type=1,serial=KLHQEMU1" -smbios "type=2,serial=KLHQEMABRD1")
  # One QEMU hostfwd port per lane: concurrent suites in different worktrees
  # (this is a multi-agent repo now) must not fight over 2222 — and nobody
  # should ever need to kill another lane's QEMU to run their own gate.
  # Port policy: KLH_TEST_PORT wins; unset = auto-pick a free ephemeral port
  # (recorded in the log so parallel lanes can see each other and nobody
  # ever kills a "stale" listener that is another lane's live suite — the
  # 2026-10-23 incident). Explicit 2222 still available if wanted.
  PORT="${KLH_TEST_PORT:-}"
  if [ -z "$PORT" ]; then
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 2222)
    klh_info "auto-picked hostfwd port $PORT (set KLH_TEST_PORT to pin)"
  fi
  for _pf in "$SCRATCH"/qemu-*.pid; do
    [ -e "$_pf" ] || continue
    _p=$(cat "$_pf" 2>/dev/null || true)
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
      klh_warn "leftover QEMU from an earlier run ($_pf, pid $_p) — killing it"
      kill "$_p" 2>/dev/null || true
    fi
    rm -f "$_pf"
  done
  port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }
  for _ in 1 2 3 4 5; do port_listening || break; sleep 2; done
  if port_listening; then
    _owner=$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $NF}' | head -1 || true)
    record fail "qemu: port $PORT free" "already in use${_owner:+ by $_owner} — kill the stale listener and re-run (see AGENTS.md watch list: leaked QEMU)"
    PORT_OK=false
  fi

  # extract kernel+initrd once for the direct-kernel boots (override + forensic)
  KERN_OK=false
  EX_MNT="$SCRATCH/iso-extract"; mkdir -p "$EX_MNT"
  if sudo mount -o ro,loop "$ISO" "$EX_MNT" 2>/dev/null; then
    KERN=$(ls "$EX_MNT"/live/vmlinuz* 2>/dev/null | head -1)
    INITRD=$(ls "$EX_MNT"/live/initrd.img* 2>/dev/null | head -1)
    sudo cp "$KERN" "$SCRATCH/vmlinuz" 2>/dev/null || true
    sudo cp "$INITRD" "$SCRATCH/initrd" 2>/dev/null || true
    sudo chmod 644 "$SCRATCH/vmlinuz" "$SCRATCH/initrd" 2>/dev/null || true
    sudo umount "$EX_MNT"
    [ -s "$SCRATCH/vmlinuz" ] && [ -s "$SCRATCH/initrd" ] && KERN_OK=true
  fi
  [ "$KERN_OK" = true ] || record skip "kernel/initrd extraction" "override+forensic boots need them"

  if [ -n "$SSH_KEY" ] && [ "$PORT_OK" = true ]; then
    # Reset the transport's host-key memory first: a stale known_hosts from a
    # different ISO makes 'accept-new' refuse the *changed* key, so every stage
    # reports "did not boot to SSH" even though the guest booted (2026-10-22:
    # the whole C-E section false-failed exactly this way against a healthy
    # guest). Real host-key drift is asserted explicitly in common_guest_checks
    # against the baked fingerprint, so the transport must not gate on it.
    rm -f "$SCRATCH/known_hosts"
    # ServerAlive*: ConnectTimeout only covers connection SETUP — a guest
    # command that blocks forever (e.g. virsh on a never-activating libvirtd
    # socket) left the channel open indefinitely and wedged the suite
    # (2026-10-24, 3/3 deterministic on bios3). timeout 120 is the outer
    # deadline (worst legitimate guest command ≈ 85 s retry loop).
    SSH_OPTS=(-F none -i "$SSH_KEY" -p "$PORT" -o UserKnownHostsFile="$SCRATCH/known_hosts" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes -o ControlMaster=auto -o ControlPath="$SCRATCH/ssh-%p" -o ControlPersist=300 kali@127.0.0.1)
    # ControlMaster multiplexing is not a speed nicety — it is CORRECTNESS:
    # the image's provision arms SSH rate limiting (>3 new connections/min
    # per source) late in boot, and the suite's poll+assert pattern is a
    # connection storm from one IP: the first ~4 connections succeed, then
    # every further one DROPs (banner-exchange timeouts, empty reads — the
    # gate-4/5/6 'empties' class, finally reproduced deterministically on a
    # quiet host 2026-10-26). One master connection = the suite is always
    # under any threshold, and each stage gets ~1 TCP handshake total.

    guest() {
      timeout 120 ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null
      local rc=$?
      # retry TRANSPORT failures only (ssh rc 255 = no connection): the very
      # first call after settle can bounce off the sshd restart window or a
      # loaded host (gate-4: exactly one failed assert per stage, all later
      # calls green). A command's own rc (0-254) is returned untouched and
      # NEVER re-executed — mutating commands must not run twice.
      if [ "$rc" -eq 255 ]; then
        timeout 120 ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null
        return $?
      fi
      return "$rc"
    }
    guest_sudo() { printf 'kali\n' | timeout 120 ssh "${SSH_OPTS[@]}" "sudo -S -p '' $*" 2>/dev/null; }

    boot_qemu() { # mode extra-args...
      local mode=$1; shift
      local pidfile="$SCRATCH/qemu-$mode.pid" serial="$SCRATCH/serial-$mode.log"
      rm -f "$pidfile"
      "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
        -cdrom "$ISO" -boot d \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
        -drive file="$SCRATCH/witness.img",format=raw,if=virtio \
        -display none -monitor none -serial "file:$serial" \
        -daemonize -pidfile "$pidfile" "$@" \
        && sleep 1 && cat "$pidfile"
    }

    kill_qemu() { local pid; pid=$(cat "$SCRATCH/qemu-$1.pid" 2>/dev/null || true); [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0; }

    wait_ssh() { # timeout_sec — waits for sshd, then for the boot to SETTLE.
      # sshd starts long before the provision oneshot finishes; asserts that
      # ran mid-provision read empties (gate-1/4 class). Settle = the console
      # banner's issue file: the banner unit is After=provision AND waits for
      # an address — when /etc/issue.d/kali-live-headless.issue exists, the
      # machine is provisioned AND networked. Deliberately NOT sudo-based:
      # guest_sudo pipes the console password, which provision CHANGES
      # mid-run, so sudo probes are unreliable exactly when we need them
      # (gate-4: 'SubState=unknown' for 480s while the guest was healthy).
      local deadline=$(( $(date +%s) + $1 ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if guest 'test -f /run/kali-live-headless.settled' >/dev/null 2>&1; then
          return 0
        fi
        sleep 5
      done
      echo "wait_ssh: boot did not settle (no banner issue file) after $1s — asserting anyway" >&2
      return 1
    }

    common_guest_checks() { # mode
      local mode=$1
      local v
      v=$(guest 'id -un')
      [ "$v" = "kali" ] && record pass "$mode: SSH key login as kali" || { record fail "$mode: SSH key login as kali"; return 1; }

      # base identity at RUNTIME: booted distro must match the suite's BASE
      v=$(guest '. /etc/os-release 2>/dev/null; printf %s "${ID:-}"')
      [ "$v" = "$KLH_OS_ID" ] \
        && record pass "$mode: booted distro is $KLH_DISTRO_NAME (os-release ID)" \
        || record fail "$mode: booted distro is $KLH_DISTRO_NAME" "got ID='$v' (suite ran BASE=$KLH_BASE)"

      # clock source (2026-10-26 v31 sqv lesson): a live stick with no
      # synced clock hard-fails apt (sqv "not live until <future>") and
      # TLS. timesyncd must be active; sync must have happened (QEMU's
      # NAT reaches the pools). Give it a bounded extra window — sync can
      # land seconds after settle on a slow boot.
      if [ "${HOTPATCH_IMAGE:-false}" = true ]; then
        record skip "$mode: timesyncd active" "hotpatched image — package + enablement are build-time, outside hotpatch scope"
        record skip "$mode: clock synchronized (NTP)" "hotpatched image — same build-time dependency"
      else
        v=$(guest 'systemctl is-active systemd-timesyncd.service 2>/dev/null')
        [ "$v" = "active" ] \
          && record pass "$mode: timesyncd active" \
          || record fail "$mode: timesyncd active" "got '$v' — wrong-clock sticks break apt/TLS (the sqv class)"
        local _synch=no _n=0
        while [ "$_synch" != yes ] && [ "$_n" -lt 10 ]; do
          _synch=$(guest 'timedatectl show -p NTPSynchronized --value 2>/dev/null' || echo no)
          [ "$_synch" = yes ] && break
          _n=$((_n + 1)); sleep 3
        done
        [ "$_synch" = yes ] \
          && record pass "$mode: clock synchronized (NTP)" \
          || record fail "$mode: clock synchronized (NTP)" "not synced after settle+30s — apt/TLS at risk"
      fi

      # hostname: HOSTNAME_SCHEME=hardware names each machine after itself
      # (<model>-<cores>c<ram>r<disk>d). The guest's own helper is the source
      # of truth — the QEMU/DMI strings vary by QEMU version, so computing the
      # expectation here beats hardcoding. A LAN duplicate may append -2..-9.
      # (KLHCONFIG HOSTNAME= is the override stage's assertion, not this one.)
      # The settle oneshot can still be inside its mDNS re-probe window when
      # SSH first answers. Reading the name before it finishes captures the
      # provision name and races the marker it writes (hotpatch #33: name
      # read as base, marker already '-2'). Wait for the unit first.
      _svc=no
      if [ "${HOSTNAME_SCHEME_EXPECTED:-static}" = hardware ]; then
        for _hi in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
          _svc=$(guest 'systemctl show -p ActiveState,Result --value kali-live-hostname-settle 2>/dev/null | paste -sd/')
          [ "$_svc" = "active/success" ] && break
          sleep 2
        done
      fi
      v=$(guest hostname)
      if [ "${HOSTNAME_SCHEME_EXPECTED:-static}" = hardware ]; then
        hw_name=$(guest '/usr/local/sbin/kali-live-hostname-derive --no-probe 2>/dev/null')
        if [ -z "$hw_name" ]; then
          record fail "$mode: hardware hostname derive available in guest"
        else
          case "$v" in
            "$hw_name"|"$hw_name"-[0-9]|"$hw_name"-[0-9][0-9])
              record pass "$mode: hardware hostname=$v" ;;
            *)
              record fail "$mode: hardware hostname" "want '$hw_name' (or -N), got '$v'" ;;
          esac
          # RemainAfterExit=yes: active/success is the finished state (the
          # wait happened above, before the name was read).
          [ "$_svc" = "active/success" ] \
            && record pass "$mode: hostname settle unit succeeded" \
            || record fail "$mode: hostname settle unit succeeded" "state '$_svc'"
          _mk=$(guest 'cat /run/kali-live-headless/hostname-auto 2>/dev/null')
          [ "$_mk" = "$v" ] \
            && record pass "$mode: hostname-auto marker matches the applied name" \
            || record fail "$mode: hostname-auto marker" "marker '$_mk' != hostname '$v'"
        fi
      else
        [ "$v" = "$HOSTNAME_EXPECTED" ] && record pass "$mode: hostname=$HOSTNAME_EXPECTED" || record fail "$mode: hostname (want $HOSTNAME_EXPECTED, got '$v')"
      fi

      local eff
      # OpenSSH ≥ 10 prints sshd -T keys in CamelCase (PermitRootLogin no);
      # older prints lowercase. Normalize before the exact-match greps.
      eff=$(guest_sudo 'sshd -T 2>/dev/null' | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication)' | tr 'A-Z' 'a-z' | sort)
      echo "$eff" | grep -q '^passwordauthentication no' && record pass "$mode: effective PasswordAuthentication no" || record fail "$mode: effective PasswordAuthentication no"
      echo "$eff" | grep -q '^permitrootlogin no'        && record pass "$mode: effective PermitRootLogin no"        || record fail "$mode: effective PermitRootLogin no"
      echo "$eff" | grep -q '^pubkeyauthentication yes'  && record pass "$mode: effective PubkeyAuthentication yes"  || record fail "$mode: effective PubkeyAuthentication yes"

      v=$(guest 'stat -c %a /home/kali/.ssh')
      [ "$v" = "700" ] && record pass "$mode: ~/.ssh mode 0700" || record fail "$mode: ~/.ssh mode 0700 ($v)"
      v=$(guest 'stat -c %a /home/kali/.ssh/authorized_keys')
      [ "$v" = "600" ] && record pass "$mode: authorized_keys mode 0600" || record fail "$mode: authorized_keys mode 0600 ($v)"
      v=$(guest 'stat -c %U /home/kali/.ssh/authorized_keys')
      [ "$v" = "kali" ] && record pass "$mode: authorized_keys owned by kali" || record fail "$mode: authorized_keys owned by kali ($v)"

      # newer NetworkManager removed connection.id from -g fields (allowed:
      # NAME,UUID,TYPE,...) — NAME is the stable field across versions
      v=$(guest 'nmcli -g NAME connection show | grep -c HEADLESS-WIFI || true')
      [ "$v" -ge 1 ] 2>/dev/null && record pass "$mode: NM profile loaded by NetworkManager" || record fail "$mode: NM profile loaded by NetworkManager"
      v=$(guest 'stat -c %a /etc/NetworkManager/system-connections/headless-wifi.nmconnection')
      [ "$v" = "600" ] && record pass "$mode: NM profile mode 0600 in guest" || record fail "$mode: NM profile mode 0600 in guest ($v)"

      v=$(guest 'nmcli -t -f TYPE,STATE device status | grep -c ^ethernet:connected || true')
      [ "$v" -ge 1 ] 2>/dev/null && record pass "$mode: ethernet auto-connected (NetworkManager)" || record fail "$mode: ethernet auto-connected"

      v=$(guest 'systemctl is-active avahi-daemon')
      [ "$v" = "active" ] && record pass "$mode: avahi-daemon active" || record fail "$mode: avahi-daemon active ($v)"

      # NB: order-insensitive by design — newer systemd (trixie) reorders
      # the requested -p fields (prints Result before ActiveState); older
      # ones honor the request order. Same class as the sshd CamelCase and
      # iptables-reorder lessons in AGENTS.md: never fixed-string-match
      # command output that a version may reorder.
      v=$(guest 'systemctl show -p ActiveState,Result --value kali-live-headless-provision 2>/dev/null | sort | paste -sd/')
      [ "$v" = "active/success" ] \
        && record pass "$mode: provision service succeeded" \
        || record fail "$mode: provision service" "state '$v' (want active+success) — journal: $(guest 'journalctl -u kali-live-headless-provision --no-pager -n 5 2>/dev/null | tail -2 | tr "\n" ";"' 2>/dev/null)"

      v=$(guest 'systemctl is-active kali-live-wifi-watchdog')
      [ "$v" = "active" ] && record pass "$mode: wifi watchdog active" || record fail "$mode: wifi watchdog active ($v)"

      # WireGuard: when the hub is staged, wg0 must EXIST with a valid dotted
      # quad. The first hardware boot of #14 shipped 5-octet addresses
      # (10.66.0.164.194) because the derivation appended two octets to a
      # three-octet base — wg0 silently never came up, and no suite check
      # looked. This would have caught it.
      if [ -n "${WG_ENDPOINT_EXPECTED:-}" ]; then
        v=$(guest 'ip -4 addr show wg0 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d" " -f2')
        if [ "$mode" = override ]; then
          # the override stage attaches a KLHCONFIG disk: wg must provision
          if [ -n "$v" ] && printf '%s' "$v" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            record pass "$mode: wg0 up with valid address" "$v"
          elif [ -n "$v" ]; then
            record fail "$mode: wg0 address malformed" "$v"
          else
            record fail "$mode: wg0 up" "no wg0 despite a config partition — check the wireguard-init journal"
          fi
        else
          # no config partition in the bios/uefi stages: the init must REFUSE
          # (an unpersisted key would silently rotate every boot)
          [ -z "$v" ] && record pass "$mode: wg0 correctly absent (no config partition to persist the key)" \
            || record fail "$mode: wg0 present WITHOUT a config partition" "$v — persistence guard broken"
        fi
      fi

      # passwordless sudo works over SSH (no password anywhere)
      if guest 'sudo -n true' 2>/dev/null; then record pass "$mode: passwordless sudo"; else record fail "$mode: passwordless sudo"; fi

      # console password randomized (shadow hash differs from Kali's stock 'kali' hash)
      if [ "$LIVE_PASSWORD_MODE_EXPECTED" = random ]; then
        v=$(guest_sudo "grep '^kali:' /etc/shadow | cut -d: -f2")
        [ -n "$v" ] && [ "$v" != "AqLUsDitNnTsw" ] && record pass "$mode: console password randomized" || record fail "$mode: console password randomized"
      fi

      # KVM stack: libvirtd reachable by the live user, host shield installed
      if [ "$WITH_KVM_EXPECTED" = true ]; then
        v=$(guest 'for i in 1 2 3 4 5 6 7 8 9 10; do timeout 5 virsh -c qemu:///system list >/dev/null 2>&1 && echo ok && exit 0; sleep 3; done; echo no')
        [ "$v" = "ok" ] && record pass "$mode: virsh usable as kali (libvirtd + group membership)" || record fail "$mode: virsh usable as kali ($v)"
        v=$(guest 'systemctl is-active kali-live-kvm-firewall')
        [ "$v" = "active" ] && record pass "$mode: kvm host-shield active" || record fail "$mode: kvm host-shield active ($v)"
      fi

      # The server must accept publickey ONLY. A client that offers no auth
      # Auth-negative probes run INSIDE the guest against its own sshd
      # (guest->127.0.0.1): a real SSH handshake with real rejection, but a
      # fresh source IP — the host-side limiter's recent list (--update on
      # every match, so one connection over threshold LATCHES the block
      # forever: each retry refreshes the window) can never sabotage the
      # probe. The old host-side probes were the last flaky class.
      local meth
      meth=$(guest 'ssh -o BatchMode=yes -o PubkeyAuthentication=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=0 -o ConnectTimeout=8 -o StrictHostKeyChecking=no kali@127.0.0.1 true 2>&1' || true)
      echo "$meth" | grep -q 'Permission denied (publickey)' && record pass "$mode: password auth rejected (publickey only)" || record fail "$mode: password auth rejected - got: $(printf '%s' "$meth" | tail -1)"

      local roottry
      roottry=$(guest 'ssh -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o ConnectTimeout=8 -o StrictHostKeyChecking=no root@127.0.0.1 true 2>&1' || true)
      echo "$roottry" | grep -q 'Permission denied' && record pass "$mode: root login rejected" || record fail "$mode: root login rejected" "got: $(printf '%s' "$roottry" | tail -1)"

      v=$(guest 'swapon --show --noheadings 2>/dev/null')
      [ -z "$v" ] && record pass "$mode: no swap in use" || record fail "$mode: swap active ($v)"

      # witness disk device differs by stage layout: -cdrom menu boots have
      # witness as the only virtio disk (vda); direct-kernel stages attach
      # the ISO as vda first (witness -> vdb).
      local witdev=/dev/vda
      [ "$mode" = forensic ] && witdev=/dev/vdb
      v=$(guest "lsblk -nrpo MOUNTPOINTS $witdev 2>/dev/null | grep -c . || true")
      [ "$v" = "0" ] && record pass "$mode: witness disk not mounted" || record fail "$mode: witness disk mounted"

      if [ -n "${BAKED_FP:-}" ]; then
        local livefp
        livefp=$(guest 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null' | awk '{print $2}')
        [ "$livefp" = "$BAKED_FP" ] && record pass "$mode: host key stable (matches baked ISO key)" || record fail "$mode: host key mismatch"
      fi
      return 0
    }

    # ---- C: BIOS
    if [ "$RUN_BIOS" = true ]; then
    truncate -s 64M "$SCRATCH/witness.img"
    WITNESS_MD5=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
    QPID=$(boot_qemu bios)
    if [ -n "$QPID" ] && wait_ssh $CD_BOOT_TIMEOUT; then
      record pass "bios: booted to SSH (accel=$ACCEL)"
      common_guest_checks bios
      timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu bios
      for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
      kill -9 "$QPID" 2>/dev/null || true
      WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
      [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "bios: witness disk byte-identical (no internal-disk writes)" || record fail "bios: witness disk WAS MODIFIED"
    else
      record fail "bios: booted to SSH" "timeout after ${CD_BOOT_TIMEOUT}s — the menu boot logs to VGA only, so serial-bios.log can be empty while the firmware is still progressing"
      kill_qemu bios
    fi

    fi
    # ---- C2: credential override from a KLHCONFIG partition (no rebuild)
    if [ "$RUN_OVERRIDE" = true ] && [ "$KERN_OK" = true ]; then
    # Boots with a second disk labeled KLHCONFIG carrying headless-wifi.conf
    # with DIFFERENT credentials; asserts the provisioner regenerated the
    # NM profile from it (this is the "password change without rebuild" path).
    if command -v mkfs.vfat >/dev/null 2>&1 || command -v mke2fs >/dev/null 2>&1; then
      truncate -s 32M "$SCRATCH/cfg.img"
      if command -v mkfs.vfat >/dev/null 2>&1; then
        mkfs.vfat -n KLHCONFIG "$SCRATCH/cfg.img" >/dev/null 2>&1
      else
        mke2fs -F -L KLHCONFIG "$SCRATCH/cfg.img" >/dev/null 2>&1
      fi
      CFG_MNT="$SCRATCH/cfgmnt"; mkdir -p "$CFG_MNT"
      if sudo mount -o loop "$SCRATCH/cfg.img" "$CFG_MNT" 2>/dev/null; then
        printf 'HOSTNAME=klh-override\nWIFI_SSID=OverrideNet\nWIFI_PSK=OverridePassphrase123\nWIFI_KEYMGMT=wpa-psk\nWIFI_HIDDEN=false\nWIFI_REGDOM=DE\n' \
          | sudo tee "$CFG_MNT/headless-wifi.conf" >/dev/null
        # The override fixture must also carry a master salt — without it,
        # the derived-WireGuard path has nothing to derive FROM, and the
        # "wg0 up with valid address" assert fails vacuously (the ONE
        # remaining suite fail, v19–v23). A fixed test salt is fine: it
        # never leaves the scratch dir.
        # ONE literal feeds staging AND every expectation below (v27 gate
        # 2026-10-25: the staged literal carried 15 '5b2f' reps = 60 chars,
        # which klh_salt_valid REJECTS (<64 hex) — the guest rightly refused
        # the salt, fell back to random identities, and the whole identity
        # cluster failed against an expectation hashing 16 reps. The length
        # guard makes that typo class impossible.)
        FIXTURE_SALT='5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f5b2f'
        [ "$(printf '%s' "$FIXTURE_SALT" | wc -c)" -eq 64 ] \
          || { echo "stage-cde: FIXTURE_SALT must be exactly 64 hex chars" >&2; exit 2; }
        printf '%s\n' "$FIXTURE_SALT" \
          | sudo tee "$CFG_MNT/master.salt" >/dev/null
        sudo umount "$CFG_MNT"
        # direct-kernel boot (fast): this stage tests the override logic,
        # not the bootloader — the BIOS/UEFI stages cover that.
        if [ "$KERN_OK" = true ]; then
          pidfile="$SCRATCH/qemu-override.pid"; rm -f "$pidfile"
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
            -kernel "$SCRATCH/vmlinuz" -initrd "$SCRATCH/initrd" \
            -append "boot=live username=kali hostname=kali console=ttyS0,115200" \
            -drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
            -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
            -drive file="$SCRATCH/cfg.img",format=raw,if=virtio \
            -display none -monitor none -serial "file:$SCRATCH/serial-override.log" \
            -daemonize -pidfile "$pidfile" >/dev/null 2>&1
          QPID=$(cat "$pidfile" 2>/dev/null || true)
          if [ -z "$QPID" ]; then
            record fail "override: QEMU launched" "pidfile empty — QEMU died at start (RAM? port? see $SCRATCH/serial-override.log)"
          elif wait_ssh $BOOT_TIMEOUT; then
            record pass "override: booted to SSH"
            v=$(guest hostname)
            [ "$v" = "klh-override" ] && record pass "override: hostname applied" || record fail "override: hostname (got '$v')"
            v=$(guest_sudo 'nmcli -g 802-11-wireless.ssid connection show HEADLESS-WIFI' 2>/dev/null)
            [ "$v" = "OverrideNet" ] && record pass "override: NM profile ssid applied" || record fail "override: NM profile ssid (got '$v')"
            v=$(guest_sudo 'nmcli -s -g 802-11-wireless-security.psk connection show HEADLESS-WIFI' 2>/dev/null)
            [ "$v" = "OverridePassphrase123" ] && record pass "override: NM profile psk applied (value not printed)" || record fail "override: NM profile psk"
            v=$(guest 'cat /run/kali-live-headless-config/headless-wifi.conf 2>/dev/null || true')
            [ -z "$v" ] && record pass "override: config partition unmounted after provisioning" || record fail "override: config partition left mounted"
            # wireguard: THIS is the stage with a KLHCONFIG disk — wg must have
            # provisioned. Caught for real on #15's first hardware boot
            # (2026-10-23): a stale WG_TUNNET staged by the parent build made
            # 5-octet addresses and wg0 silently never came up, and this assert
            # was (wrongly) living in common_guest_checks, which the override
            # stage never calls.
            if [ -n "${WG_ENDPOINT_EXPECTED:-}" ]; then
              # boot-time wg-quick fails when DNS can't resolve the endpoint
              # yet (provision runs pre-network; the ensure timer exists for
              # exactly this). Mirror the product's own self-healing: nudge
              # one ensure pass, then judge — the interface, not the boot
              # instant, is the contract.
              v=$(guest 'ip -4 addr show wg0 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d" " -f2')
              if [ -z "$v" ]; then
                guest_sudo '/usr/local/sbin/kali-live-wireguard-init --ensure' >/dev/null 2>&1 || true
                sleep 3
                v=$(guest 'ip -4 addr show wg0 2>/dev/null | grep -oE "inet [0-9.]+" | cut -d" " -f2')
              fi
              if [ -n "$v" ] && printf '%s' "$v" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                record pass "override: wg0 up with valid address" "$v"
              elif [ -n "$v" ]; then
                record fail "override: wg0 address malformed" "$v"
              else
                w=$(guest 'grep ^Address /etc/wireguard/wg0.conf 2>/dev/null || true')
                record fail "override: wg0 up" "no wg0; wg0.conf Address: ${w:-none} — staged WG_TUNNET stale?"
              fi
            fi
            # ---- identity unification end-to-end (2026-10-24/25): with a
            # valid fixture salt aboard, EVERY identity must be derived from
            # it — npub == derive_identity(salt, machine) computed INSIDE the
            # guest (self-consistency, no host-side fingerprint knowledge
            # needed), and the fips seeding must actually have run (the
            # 2026-10-24 live finding: fips.yaml never existed).
            _salt="$FIXTURE_SALT"
            _npub_run=$(guest 'cat /run/kali-live-headless-npub 2>/dev/null')
            _npub_der=$(guest_sudo "python3 /usr/local/lib/kali-live-headless/derive_identity.py $_salt --machine --purpose fips 2>/dev/null | cut -f1")
            if [ -n "$_npub_run" ] && [ "$_npub_run" = "$_npub_der" ]; then
              record pass "identity: npub == salt-derived npub (one entropy source)"
            else
              record fail "identity: npub == salt-derived npub" "run='$_npub_run' derived='$_npub_der'"
            fi
            if guest_sudo 'test -s /etc/fips/fips.pub && test -f /etc/fips/fips.yaml && systemctl is-active fips >/dev/null' >/dev/null 2>&1; then
              record pass "identity: fips seeded (fips.yaml + fips.key)"
            else
              record fail "identity: fips seeded (fips.yaml + fips.key)"
            fi
            if [ "$(guest_sudo 'systemctl is-enabled fips 2>/dev/null')" = "enabled" ]; then
              record pass "identity: fips service enabled"
            else
              record fail "identity: fips service enabled"
            fi
            # ---- blackbox: the forensic boot record must exist IN the guest
            # (RAM or persisted) with the salt digest — proving the recorder
            # runs at all (2026-10-25 feature, first suite coverage here).
            _bb=$(guest_sudo 'ls /run/klh-blackbox/logs/boot-*.log 2>/dev/null | head -1')
            if [ -n "$_bb" ] && guest_sudo "grep -q 'salt_sha256' '$_bb'" >/dev/null 2>&1; then
              record pass "blackbox: boot record written (guest $_bb)"
            else
              record fail "blackbox: boot record written" "no boot-*.log with salt_sha256 under /run/klh-blackbox/logs"
            fi
            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu override
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
            # ---- post-poweroff: what the guest WROTE to the config disk is
            # the durable half of the story — key provenance + blackbox
            # persistence + the salt itself untouched.
            if sudo mount -o loop "$SCRATCH/cfg.img" "$CFG_MNT" 2>/dev/null; then
              if sudo grep -q '^KEYSOURCE=derived' "$CFG_MNT/wireguard.conf" 2>/dev/null; then
                record pass "override: wg key persisted with KEYSOURCE=derived"
              else
                record fail "override: wg key KEYSOURCE=derived" "$(sudo grep '^KEYSOURCE' "$CFG_MNT/wireguard.conf" 2>/dev/null || echo 'no wireguard.conf/KEYSOURCE')"
              fi
              _bbf=$(sudo ls "$CFG_MNT/logs"/boot-*.log 2>/dev/null | head -1)
              if [ -n "$_bbf" ] && sudo grep -q 'persistent=yes' "$_bbf" 2>/dev/null; then
                record pass "blackbox: boot record persisted to KLHCONFIG"
              else
                record fail "blackbox: boot record persisted to KLHCONFIG" "no logs/boot-*.log with persistent=yes on the fixture disk"
              fi
              _expdig=$(printf '%s\n' "$FIXTURE_SALT" | sha256sum | cut -c1-16)
              if [ -n "$_bbf" ] && sudo grep -q "salt_sha256 : $_expdig" "$_bbf" 2>/dev/null; then
                record pass "blackbox: salt digest matches fixture salt"
              else
                record fail "blackbox: salt digest matches fixture salt" "expected $_expdig in $_bbf"
              fi
              sudo umount "$CFG_MNT" 2>/dev/null || true
            else
              record fail "override: post-poweroff cfg.img remount" "cannot re-mount fixture disk for write-back asserts"
            fi
          else
            record fail "override: booted to SSH" "timeout after ${BOOT_TIMEOUT}s — see $SCRATCH/serial-override.log"
            kill_qemu override
          fi
        else
          record skip "config override" "kernel/initrd not extracted"
        fi
      else
        record skip "config override" "could not loop-mount cfg.img"
      fi
    else
      record skip "config override" "no mkfs.vfat/mke2fs on host"
    fi
    fi   # RUN_OVERRIDE gate

    # ---- D: UEFI
    OVMF_CODE=""; OVMF_VARS=""
    for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF_CODE.fd; do
      [ -f "$c" ] && OVMF_CODE=$c && break
    done
    for v in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/ovmf/OVMF_VARS.fd; do
      [ -f "$v" ] && OVMF_VARS=$v && break
    done
    if [ "$RUN_UEFI" = true ] && [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
      cp "$OVMF_VARS" "$SCRATCH/ovmf-vars.fd"
      truncate -s 64M "$SCRATCH/witness.img"
      WITNESS_MD5=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
      QPID=$(boot_qemu uefi \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$SCRATCH/ovmf-vars.fd")
      if [ -n "$QPID" ] && wait_ssh $CD_BOOT_TIMEOUT; then
        record pass "uefi: booted to SSH"
        common_guest_checks uefi
        timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu uefi
        for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
        kill -9 "$QPID" 2>/dev/null || true
        WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
        [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "uefi: witness disk byte-identical" || record fail "uefi: witness disk WAS MODIFIED"
      else
        record fail "uefi: booted to SSH" "timeout after ${CD_BOOT_TIMEOUT}s — see $SCRATCH/serial-uefi.log"
        kill_qemu uefi
      fi
    else
      record skip "uefi" "OVMF firmware not found or disabled"
    fi

    # ---- E: forensic boot entry (direct kernel boot with the syslinux entry's cmdline)
    if [ "$RUN_FORENSIC" = true ] && [ "$KERN_OK" = true ]; then
          truncate -s 64M "$SCRATCH/witness.img"
          WITNESS_MD5=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
          pidfile="$SCRATCH/qemu-forensic.pid"; rm -f "$pidfile"
          "$QEMU_BIN" -machine accel=$ACCEL -m 4096 -smp 4 "${CPU[@]}" "${KLH_SMBIOS[@]}" \
            -kernel "$SCRATCH/vmlinuz" -initrd "$SCRATCH/initrd" \
            -append "boot=live username=kali hostname=kali console=ttyS0,115200 systemd.swap=no noautomount" \
            -drive file="$ISO",format=raw,if=virtio,media=disk,readonly=on \
            -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
            -drive file="$SCRATCH/witness.img",format=raw,if=virtio \
            -display none -monitor none -serial "file:$SCRATCH/serial-forensic.log" \
            -daemonize -pidfile "$pidfile" >/dev/null 2>&1
          QPID=$(cat "$pidfile" 2>/dev/null || true)

          if [ -z "$QPID" ]; then
            record fail "qemu launch" "pidfile empty — QEMU died at start (RAM? port?)"
          elif wait_ssh $BOOT_TIMEOUT; then
            record pass "forensic: booted to SSH"
            common_guest_checks forensic
            [ -z "$(guest 'swapon --show --noheadings 2>/dev/null')" ] && record pass "forensic: no swap (systemd.swap=no)" || record fail "forensic: swap active"
            timeout 30 guest_sudo 'poweroff' >/dev/null 2>&1 || kill_qemu forensic
            for _ in $(seq 1 60); do kill -0 "$QPID" 2>/dev/null || break; sleep 2; done
            kill -9 "$QPID" 2>/dev/null || true
            WITNESS_MD5_AFTER=$(md5sum "$SCRATCH/witness.img" | awk '{print $1}')
            [ "$WITNESS_MD5" = "$WITNESS_MD5_AFTER" ] && record pass "forensic: witness disk byte-identical (no automount/no writes)" || record fail "forensic: witness disk WAS MODIFIED"
          else
            record fail "forensic: booted to SSH" "timeout after ${BOOT_TIMEOUT}s — see $SCRATCH/serial-forensic.log"
            kill_qemu forensic
          fi
    fi

  elif [ "$PORT_OK" != true ]; then
    : # already recorded as a failure in the port preflight above — do not
      # add three more misleading "did not boot to SSH" failures
  else
    record skip "qemu" "no SSH private key available for the baked public key"
  fi
fi
