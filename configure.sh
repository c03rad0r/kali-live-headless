#!/usr/bin/env bash
# configure.sh — collect Wi-Fi settings and SSH public key, write ./config
#
# The Wi-Fi passphrase is read WITHOUT echoing it to the terminal and is
# written to ./config (chmod 600, git-ignored). It is NOT encrypted: the
# live system must be able to join Wi-Fi without anyone typing anything,
# so the credential has to be recoverable from the boot medium. See
# README.md "Threat model" before using this on a network you care about.
#
# Usage:
#   ./configure.sh                      # fully interactive
#   WIFI_PSK=... ./configure.sh --hostname h --ssid S --pubkey path --regdom US
#                                       # non-interactive (PSK from env)

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

CONFIG_FILE="$REPO_DIR/config"

ASSUME_YES=false
OPT_HOSTNAME="" OPT_HOSTNAME_SCHEME="" OPT_SSID="" OPT_KEYMGMT="" OPT_HIDDEN="" OPT_REGDOM=""
OPT_PUBKEY="" OPT_EXTRA=""
OPT_BOOTDEFAULT="" OPT_PASSMODE="" OPT_KVM=""
OPT_WG_ENDPOINT="${WG_ENDPOINT:-}" OPT_WG_PEER="${WG_PEER_PUBKEY:-}" OPT_WG_NET="" OPT_WG_PORT="" OPT_WG_HUB="${WG_HUB_ADDR:-}"
OPT_WG_ENROLL_HUB="${WG_ENROLL_HUB_NPUB:-}" OPT_WG_ENROLL_RELAYS="${WG_ENROLL_RELAYS:-}"

usage() {
  cat <<EOF
Usage: ./configure.sh [OPTIONS]

Options:
  -n, --hostname NAME     Static hostname (default: kali-live; fallback in hardware mode)
      --hostname-scheme S hardware (default) derives <model>-<cores>c<ram>r<disk>d
                          at boot and appends -2 for identical machines; static
                          uses --hostname verbatim
  -s, --ssid SSID         Wi-Fi SSID
  -K, --keymgmt MGMT      wpa-psk (WPA2/WPA3-transition) or sae (WPA3-only)
  -H, --hidden true|false SSID is hidden (default: false)
  -r, --regdom CC         ISO 3166-1 alpha-2 regulatory domain (e.g. US); empty skips
  -k, --pubkey PATH       Path to SSH public key (e.g. ~/.ssh/id_ed25519.pub)
  -e, --extra-pubkeys P   Extra public keys, space-separated paths
  -B, --boot-default D    Default boot entry: live (default) or forensic
  -P, --password-mode M   Console password: random (default) or kali
      --with-kvm B        Bake in KVM/libvirt stack: true (default) or false
      --wg-endpoint H     WireGuard hub (host or host:port) — enables the
                          ssh-over-wireguard access channel; the stick's
                          private key is generated on first boot (not baked)
      --wg-peer KEY       The hub's PUBLIC key (44-char base64 from wg pubkey)
      --wg-net NET        Tunnel /24 first three octets (default: 10.66.0)
      --wg-hub-addr A     Hub's own tunnel address if outside the tunnel net
                          (e.g. 10.99.0.1 when joining an existing hub)
      --wg-port PORT      Hub UDP port (default: 51820)
  -v, --variant V         Image flavour: minimal (default — appliance: our
                          headless/KVM stack only), default (kali-linux-default
                          incl. metasploit/gvm/texlive, ~4x bigger), light
                          (core + Xfce desktop, for virt-manager GUI use)
      --toram-entry B     Ship a "Live (load to RAM)" boot entry (default true)
  -y, --assume-yes        Overwrite an existing ./config without asking
  -h, --help              This help

The Wi-Fi passphrase is always prompted for (hidden input) unless the
WIFI_PSK environment variable is set.
EOF
  exit 0
}

[ $# -eq 0 ] || while [ $# -gt 0 ]; do
  case "$1" in
    -n|--hostname)       OPT_HOSTNAME=${2:?}; shift 2 ;;
    --hostname-scheme)   OPT_HOSTNAME_SCHEME=${2:?}; shift 2 ;;
    -s|--ssid)           OPT_SSID=${2:?}; shift 2 ;;
    -K|--keymgmt)        OPT_KEYMGMT=${2:?}; shift 2 ;;
    -H|--hidden)         OPT_HIDDEN=${2:?}; shift 2 ;;
    -r|--regdom)         OPT_REGDOM=${2:?}; shift 2 ;;
    -k|--pubkey)         OPT_PUBKEY=${2:?}; shift 2 ;;
    -e|--extra-pubkeys)  OPT_EXTRA=${2:?}; shift 2 ;;
    -B|--boot-default)   OPT_BOOTDEFAULT=${2:?}; shift 2 ;;
    -P|--password-mode)  OPT_PASSMODE=${2:?}; shift 2 ;;
    --with-kvm)          OPT_KVM=${2:?}; shift 2 ;;
    --wg-endpoint)       OPT_WG_ENDPOINT=${2:?}; shift 2 ;;
    --wg-peer)           OPT_WG_PEER=${2:?}; shift 2 ;;
    --wg-net)            OPT_WG_NET=${2:?}; shift 2 ;;
    --wg-hub-addr)       OPT_WG_HUB=${2:?}; shift 2 ;;
    --wg-port)           OPT_WG_PORT=${2:?}; shift 2 ;;
    --bitlocker-unlock) OPT_BITLOCKER=${2:?}; shift 2 ;;
    -v|--variant)        OPT_VARIANT=${2:?}; shift 2 ;;
    --toram-entry)       OPT_TORAM=${2:?}; shift 2 ;;
    --wg-enroll-hub)     OPT_WG_ENROLL_HUB=${2:?}; shift 2 ;;
    --wg-enroll-relays)  OPT_WG_ENROLL_RELAYS=${2:?}; shift 2 ;;
    -y|--assume-yes)     ASSUME_YES=true; shift ;;
    -h|--help)           usage ;;
    *) klh_die "unknown option: $1 (see --help)" ;;
  esac
done

prompt_default() { # var question default
  local __var=$1 __q=$2 __def=$3 __ans
  read -r -p "$__q [$__def]: " __ans || true
  [ -n "$__ans" ] || __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
}

prompt_choice() { # var question default valid...
  local __var=$1 __q=$2 __def=$3; shift 3
  local __ans
  while :; do
    read -r -p "$__q [$__def]: " __ans || true
    [ -n "$__ans" ] || __ans="$__def"
    for __v in "$@"; do [ "$__ans" = "$__v" ] && printf -v "$__var" '%s' "$__ans" && return 0; done
    echo "  Please enter one of: $*" >&2
  done
}

# ------------------------------------------------------------------ inputs
HOSTNAME=${OPT_HOSTNAME:-}
if [ -z "$HOSTNAME" ]; then prompt_default HOSTNAME "Static hostname (fallback in hardware mode)" "kali-live"; fi
klh_validate_hostname "$HOSTNAME" || klh_die "invalid hostname '$HOSTNAME'"

# Self-describing hostnames: the machine names itself after its own hardware
# (x280-8c16r256d), so identical sticks on different laptops stay tellable
# apart. Same stick on another machine = that machine's name. static keeps
# the old one-name-per-image behavior.
HOSTNAME_SCHEME=${OPT_HOSTNAME_SCHEME:-}
if [ -z "$HOSTNAME_SCHEME" ]; then
  cat >&2 <<'EOF'
Hostname policy:
  1. hardware  derive <model>-<cores>c<ram>r<disk>d at boot, e.g. x280-8c16r256d;
               identical machines get -2/-3 once the LAN is up (default)
  2. static    use the hostname above on every machine (<hostname>.local)
EOF
  prompt_choice HOSTNAME_SCHEME "Choose" "hardware" hardware static
fi
case "$HOSTNAME_SCHEME" in hardware|static) ;; *) klh_die "hostname scheme must be hardware or static" ;; esac

WIFI_SSID=${OPT_SSID:-}
if [ -z "$WIFI_SSID" ]; then read -r -p "Wi-Fi SSID (network name): " WIFI_SSID || klh_die "stdin closed"; fi
klh_validate_ssid "$WIFI_SSID" || klh_die "invalid SSID (1-32 chars, no control chars, no leading/trailing whitespace)"

WIFI_PSK="${WIFI_PSK:-}"
if [ -n "$WIFI_PSK" ]; then
  klh_info "Using Wi-Fi passphrase from WIFI_PSK environment variable"
else
  while [ ${#WIFI_PSK} -lt 8 ]; do
    read -r -s -p "Wi-Fi passphrase (WPA2/WPA3 PSK, input hidden): " WIFI_PSK; echo >&2
    klh_validate_psk "$WIFI_PSK" || { klh_warn "passphrase must be 8-63 chars, no leading/trailing whitespace"; WIFI_PSK=""; continue; }
    read -r -s -p "Confirm passphrase: " CONFIRM; echo >&2
    [ "$WIFI_PSK" = "$CONFIRM" ] || { klh_warn "passphrases differ, try again"; WIFI_PSK=""; }
  done
fi
klh_validate_psk "$WIFI_PSK" || klh_die "invalid Wi-Fi passphrase"

WIFI_KEYMGMT=${OPT_KEYMGMT:-}
if [ -z "$WIFI_KEYMGMT" ]; then
  cat >&2 <<'EOF'
Authentication mode:
  1. wpa-psk  WPA2-Personal; also works on WPA2/WPA3 "transition" networks (most compatible - default)
  2. sae      WPA3-Personal only (requires AP + Wi-Fi driver + wpa_supplicant SAE support)
EOF
  prompt_choice WIFI_KEYMGMT "Choose" "wpa-psk" wpa-psk sae
fi
klh_validate_keymgmt "$WIFI_KEYMGMT" || klh_die "WIFI_KEYMGMT must be wpa-psk or sae"

WIFI_HIDDEN=${OPT_HIDDEN:-}
if [ -z "$WIFI_HIDDEN" ]; then prompt_choice WIFI_HIDDEN "Is the SSID hidden (not broadcast)?" "false" true false; fi
klh_validate_bool "$WIFI_HIDDEN" || klh_die "hidden must be true or false"

WIFI_REGDOM=${OPT_REGDOM-__UNSET}
if [ "$WIFI_REGDOM" = "__UNSET" ]; then prompt_default WIFI_REGDOM "Wi-Fi regulatory domain (two letters, empty to skip)" ""; fi
klh_validate_regdom "$WIFI_REGDOM" || klh_die "regulatory domain must be empty or two uppercase letters"

SSH_PUBKEY_PATH=${OPT_PUBKEY:-}
if [ -z "$SSH_PUBKEY_PATH" ]; then
  # shellcheck disable=SC2088  # tilde is a display default; expanded later by klh_expand_tilde
  prompt_default SSH_PUBKEY_PATH "Path to SSH PUBLIC key" "~/.ssh/id_ed25519.pub"
fi
SSH_PUBKEY_PATH=$(klh_expand_tilde "$SSH_PUBKEY_PATH")
klh_require_cmd ssh-keygen
[ -f "$SSH_PUBKEY_PATH" ] || klh_die "public key file not found: $SSH_PUBKEY_PATH"
if ! ssh-keygen -lf "$SSH_PUBKEY_PATH" > /dev/null 2>&1; then
  klh_die "not a valid SSH public key file: $SSH_PUBKEY_PATH"
fi
PUBKEY_FP=$(ssh-keygen -lf "$SSH_PUBKEY_PATH" | sed 's/^ *[0-9]* //')

SSH_EXTRA_PUBKEYS=${OPT_EXTRA:-}
EXTRA_FPS=""
if [ -n "$SSH_EXTRA_PUBKEYS" ]; then
  for k in $SSH_EXTRA_PUBKEYS; do
    k=$(klh_expand_tilde "$k")
    [ -f "$k" ] || klh_die "extra public key not found: $k"
    ssh-keygen -lf "$k" > /dev/null 2>&1 || klh_die "invalid extra public key: $k"
    EXTRA_FPS="${EXTRA_FPS}$(ssh-keygen -lf "$k" | sed 's/^ *[0-9]* //') | "
  done
fi

# --------------------------------------------------- boot + security options
BOOT_DEFAULT=${OPT_BOOTDEFAULT:-}
if [ -z "$BOOT_DEFAULT" ]; then
  cat >&2 <<'EOF'
Default boot entry (auto-boots after 5s either way):
  1. live     standard Kali Live
  2. forensic also disables swap and internal-disk automounting
EOF
  prompt_choice BOOT_DEFAULT "Choose" "live" live forensic
fi
klh_validate_boot_default "$BOOT_DEFAULT" || klh_die "boot default must be live or forensic"

LIVE_PASSWORD_MODE=${OPT_PASSMODE:-}
if [ -z "$LIVE_PASSWORD_MODE" ]; then
  cat >&2 <<'EOF'
Console password for the live user 'kali' (SSH is key-only regardless):
  1. random  randomized at every boot; nobody can log in at the console
             (sudo is passwordless over SSH, so this rarely matters)
  2. kali    standard Kali live behavior (kali/kali at the console)
EOF
  prompt_choice LIVE_PASSWORD_MODE "Choose" "random" random kali
fi
klh_validate_password_mode "$LIVE_PASSWORD_MODE" || klh_die "password mode must be random or kali"

WITH_KVM=${OPT_KVM:-}
if [ -z "$WITH_KVM" ]; then prompt_choice WITH_KVM "Bake in the KVM/libvirt stack?" "true" true false; fi
VARIANT=${OPT_VARIANT:-minimal}
TORAM_ENTRY=${OPT_TORAM:-true}
klh_validate_bool "$WITH_KVM" || klh_die "--with-kvm must be true or false"
klh_validate_bool "$TORAM_ENTRY" || klh_die "--toram-entry must be true or false"

# WireGuard access channel (non-interactive only: flags or environment; all
# staged values are NON-secret — the stick generates its own private key on
# first boot and persists it to the KLHCONFIG partition, nothing is baked).
WG_ENDPOINT=${OPT_WG_ENDPOINT:-}
WG_PEER_PUBKEY=${OPT_WG_PEER:-}
WG_TUNNET=${OPT_WG_NET:-}
WG_PORT=${OPT_WG_PORT:-}
VMSTORE_BITLOCKER=${OPT_BITLOCKER:-}
WG_HUB_ADDR=${OPT_WG_HUB:-}
WG_ENROLL_HUB_NPUB=${OPT_WG_ENROLL_HUB:-}
WG_ENROLL_RELAYS=${OPT_WG_ENROLL_RELAYS:-}

# ------------------------------------------------------------------- write
if [ -e "$CONFIG_FILE" ] && [ "$ASSUME_YES" != true ]; then
  read -r -p "Overwrite existing $CONFIG_FILE? [y/N] " ans || true
  case "$ans" in y|Y|yes|YES) ;; *) klh_die "aborted, existing config kept";; esac
fi

TMP=$(mktemp)
{
  echo "# Generated by ./configure.sh on $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo "# PLAINTEXT SECRET BELOW (required for unattended Wi-Fi) — keep chmod 600, never commit."
  printf 'HOSTNAME=%q\n'    "$HOSTNAME"
  printf 'HOSTNAME_SCHEME=%q\n' "$HOSTNAME_SCHEME"
  printf 'WIFI_SSID=%q\n'   "$WIFI_SSID"
  printf 'WIFI_PSK=%q\n'    "$WIFI_PSK"
  printf 'WIFI_KEYMGMT=%q\n' "$WIFI_KEYMGMT"
  printf 'WIFI_HIDDEN=%q\n' "$WIFI_HIDDEN"
  printf 'WIFI_REGDOM=%q\n' "$WIFI_REGDOM"
  printf 'SSH_PUBKEY_PATH=%q\n' "$SSH_PUBKEY_PATH"
  printf 'SSH_EXTRA_PUBKEYS=%q\n' "$SSH_EXTRA_PUBKEYS"
  printf 'BOOT_DEFAULT=%q\n' "$BOOT_DEFAULT"
  printf 'LIVE_PASSWORD_MODE=%q\n' "$LIVE_PASSWORD_MODE"
  printf 'WITH_KVM=%q\n' "$WITH_KVM"
  printf 'WG_ENDPOINT=%q\n' "$WG_ENDPOINT"
  printf 'WG_PEER_PUBKEY=%q\n' "$WG_PEER_PUBKEY"
  printf 'WG_TUNNET=%q\n' "$WG_TUNNET"
  printf 'WG_PORT=%q\n' "$WG_PORT"
  printf 'VMSTORE_BITLOCKER=%q\n' "$VMSTORE_BITLOCKER"
  printf 'VARIANT=%q\n' "$VARIANT"
  printf 'TORAM_ENTRY=%q\n' "$TORAM_ENTRY"
  printf 'WG_HUB_ADDR=%q\n' "$WG_HUB_ADDR"
  printf 'WG_ENROLL_HUB_NPUB=%q\n' "$WG_ENROLL_HUB_NPUB"
  printf 'WG_ENROLL_RELAYS=%q\n' "$WG_ENROLL_RELAYS"
} > "$TMP"
chmod 600 "$TMP"
mv -f "$TMP" "$CONFIG_FILE"

echo
klh_ok "wrote $CONFIG_FILE (mode 600, git-ignored)"
if [ "$HOSTNAME_SCHEME" = hardware ]; then
  klh_info "hostname        : hardware-derived per machine (static fallback: $HOSTNAME)"
else
  klh_info "hostname        : $HOSTNAME  (mDNS: $HOSTNAME.local)"
fi
klh_info "Wi-Fi SSID      : $WIFI_SSID  ($WIFI_KEYMGMT$( [ "$WIFI_HIDDEN" = true ] && echo ', hidden'))"
[ -n "$WIFI_REGDOM" ] && klh_info "regdom          : $WIFI_REGDOM" || klh_info "regdom          : (not set)"
klh_info "authorized key  : $PUBKEY_FP"
[ -n "$EXTRA_FPS" ] && klh_info "extra keys      : $EXTRA_FPS"
klh_info "boot default    : $BOOT_DEFAULT (auto-boots after 5s)"
klh_info "console password: $LIVE_PASSWORD_MODE"
klh_info "wireguard       : ${WG_ENDPOINT:-off}${WG_TUNNET:+ ($WG_TUNNET.0/24 via $WG_TUNNET hub)}"
[ -n "$WG_ENROLL_HUB_NPUB" ] && klh_info "wg enrollment   : via hub $WG_ENROLL_HUB_NPUB (${WG_ENROLL_RELAYS:-no relays!})"
klh_info "variant         : $VARIANT"
klh_info "toram boot entry: $TORAM_ENTRY"
klh_info "KVM stack       : $WITH_KVM$( [ "$WITH_KVM" = true ] && echo ' (libvirtd + virt-manager, host shielded from guests)')"
cat <<'EOF'

Reminder: the Wi-Fi passphrase is stored recoverably (plaintext) in ./config
and will be baked into the ISO. Anyone with physical access to the USB stick
(or the ISO file) can extract it. Rotate the passphrase if the stick is lost.
Next: ./build.sh
EOF
