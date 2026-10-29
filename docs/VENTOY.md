# Ventoy multiboot USB

This adds a Ventoy-backed multiboot builder to the repo. It is independent of
the Kali live-build path: no upstream files are modified, and the existing
`build.sh` / `flash.sh` flow still works.

The stick boots:

| Entry | Version | Notes |
|---|---|---|
| Archipelago | 1.9.0-alpha (unbundled) | needs internet during install |
| Debian | 13.7 netinst | needs network for packages |
| Tails | 7.15.1 | no Ventoy persistence; Tails needs its own persistent partition |
| Ubuntu | 25.10 Desktop | installer only |
| Kali | 2026.3 Live | stock ISO; the headless build can be added later |
| Omarchy | 4.0.6 | Arch-based; installer likely needs internet |

No persistence images are created.

## Requirements

- Linux with `ansible`, `python3`, `curl`, `rsync`, `mount.exfat`
- A USB stick of at least 24 GB for the full six-ISO catalog
- Ventoy **1.1.18** is downloaded and checksum-verified by the role

## Targets

```bash
make usb-list                         # removable disks, serials, by-id
make ventoy-plan USB=/dev/sdc         # read-only: size, catalog, free space
make ventoy-isos                      # download + verify into ~/.cache/ventoy/isos
make ventoy-all USB=/dev/sdc CONFIRM=yes
make ventoy-install USB=/dev/sdc CONFIRM=yes
make ventoy-sync USB=/dev/sdc CONFIRM=yes
make ventoy-verify USB=/dev/sdc
make ventoy-update USB=/dev/sdc CONFIRM=yes
make ventoy-archive-logs              # Ubuntu live-install logs, before wiping
make ventoy-test-loop                 # sparse loop install test (root)
make ventoy-lint
```

`ventoy-install`, `ventoy-sync`, `ventoy-verify` and `ventoy-update` use
`sudo`; `make` passes `-K` so Ansible asks once. `ventoy-plan` and
`ventoy-isos` need no privileges.

If `SERIAL=` is omitted on a destructive target, the role pauses and asks you
to type the disk serial. Supplying `SERIAL=...` is for scripted runs.

## Known limitation: sudo-rs

On hosts whose `sudo` is **sudo-rs** (Ubuntu 25.10+/26.04), Ansible's `become`
plugin does not recognise the prompt and the first privileged task fails with:

```
Timed out waiting for become success or become password prompt
```

This breaks `ventoy-install`, `ventoy-sync` and `ventoy-verify` *on the
control host*; the roles themselves are fine. Until the role learns a
sudo-rs-compatible invocation, run the pinned installer with plain sudo:

```bash
# download + verify + install, no Ansible
make -C ~/hermes-migration rescue-usb-install-ventoy USB=/dev/sda CONFIRM=yes
```

That target lives in the backup programme repository and performs the same
checksum-pinned Ventoy install.

## Safety model

The role refuses to continue unless all of these hold:

1. The path resolves to one whole disk, not a partition.
2. Transport is USB or the device is removable (loop devices only with
   `ALLOW_LOOP=true`).
3. The disk is not the running root disk.
4. The disk is not a USB disk larger than 2 TB (protects the backup HDD).
5. The disk reports a serial.
6. The catalog fits with the configured free-space margin.
7. `CONFIRM=yes` is present for install/sync/update.
8. The typed or supplied serial matches.

`ventoy-plan` is read-only. `ventoy-install` unmounts only the target's own
mounted paths.

## Workflow

```bash
make usb-list
make ventoy-plan USB=/dev/sdc
make ventoy-archive-logs            # if the stick has Ubuntu install logs
make ventoy-all USB=/dev/sdc CONFIRM=yes
make ventoy-verify USB=/dev/sdc
```

`ventoy-all` runs, in order:

1. preflight and plan
2. ISO download and checksum verification (before any write)
3. Ventoy install (GPT, Secure Boot support)
4. mount the exFAT partition, write `ventoy/ventoy.json`, copy ISOs, sync
5. read every ISO back and verify its hash, validate the JSON

For a separate download step:

```bash
make ventoy-isos
make ventoy-sync USB=/dev/sdc CONFIRM=yes
```

## Catalog pins

`ventoy/catalog.yml` pins every filename, URL and SHA-256. The role fails
closed on a missing or mismatched hash. When an upstream point release moves,
update the version, filename, URL and hash together, then run `make
ventoy-isos`.

Pinned at the time of writing:

```text
Ventoy 1.1.18   d86ff9de63d94c8b8f1f6b14d23c55af4b88e8207bf2893890892a6a97b1ad54
Archipelago     aad5f0350428976969043079a63b0e7a8264dcee2574526bd34719c798c750af
Debian 13.7     a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355
Ubuntu 25.10    32e30d72ae4798c633323a2684d94a11582bb03a6ab38d2b0d5ae5eabc5e577b
Kali 2026.3     93a40ef53936719119824c3f0f0742ab50a045e2e082b95e382cf9f2f1f8acbb
Omarchy 4.0.6   b542db5fecc37395d9af6654a8146ebed225f275ae4d5a6fcf432e40afe7bb88
Tails 7.15.1    f0e68387ebe327808c0a037886f804f7b2268ae8c66a677e3a6c6241d764e3c7
```

Tails publishes OpenPGP signatures rather than a standalone SHA-256 file. The
Tails hash was recorded after verifying the download against the Tails
signing key (`A490 D0F4 D311 A415 3E2B B7CA DBB8 02B2 58AC D84F`).

## Loop-device test

```bash
sudo make ventoy-test-loop
```

Creates an 8 GB sparse image, attaches a loop device, installs Ventoy and
checks for the exFAT `Ventoy` partition. It never touches a real USB device.
`Ventoy2Disk.sh` may reject loop devices on some versions; that is why the
physical-stick path remains the final proof.

## Secure Boot

Ventoy installs with Secure Boot support (`-s`). On first boot the firmware
may require MOK enrollment, or Secure Boot can be disabled for the target
machine. Archipelago's installer may also need Secure Boot off; test that on
the machine, not on the stick.

## Tails caveat

Ventoy boots the Tails ISO, but Tails Persistent Storage expects a
Tails-created partition layout. Do not promise persistence from this stick.
If persistent Tails matters, dedicate a stick and use Tails' own installer.

## Files

```text
Makefile
ansible.cfg
inventory/localhost.yml
playbooks/ventoy.yml
roles/ventoy/
ventoy/catalog.yml
scripts/usb-list.py
scripts/ventoy-archive-logs.sh
scripts/ventoy-test-loop.sh
```

Upstream's Kali live-build files are untouched.
