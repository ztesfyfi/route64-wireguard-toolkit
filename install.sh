#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG=""
while (($#)); do case "$1" in --config) [[ $# -ge 2 ]] || { echo 'Missing config path' >&2; exit 2; }; CONFIG="$2"; shift 2;; -h|--help) echo 'Usage: sudo bash install.sh --config PATH'; exit 0;; *) echo "Unknown argument: $1" >&2; exit 2;; esac; done
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo 'Specify an existing config with --config PATH' >&2; exit 1; }
chmod 600 "$CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"
need(){ [[ -n "${!1:-}" ]] || { echo "Missing config value: $1" >&2; exit 1; }; }
cidr6(){ [[ "$1" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]]; }
need ROUTE64_PUBLIC_KEY; need ROUTE64_ENDPOINT; need ROUTE64_ADDRESS; need ROUTED_PREFIX
cidr6 "$ROUTE64_ADDRESS" || { echo 'ROUTE64_ADDRESS must be IPv6 CIDR' >&2; exit 1; }
cidr6 "$ROUTED_PREFIX" || { echo 'ROUTED_PREFIX must be IPv6 CIDR' >&2; exit 1; }
[[ ! -e /etc/wireguard/wg0.conf ]] || { echo 'Refusing to overwrite existing wg0.conf' >&2; exit 1; }
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
 [[ ! -e /etc/wireguard/wg1.conf ]] || { echo 'Refusing to overwrite existing wg1.conf' >&2; exit 1; }; need WG1_LISTEN_PORT
 [[ "$WG1_LISTEN_PORT" =~ ^[0-9]{1,5}$ ]] && ((WG1_LISTEN_PORT>0 && WG1_LISTEN_PORT<65536)) || { echo 'Invalid WG1_LISTEN_PORT' >&2; exit 1; }
 if [[ -z "${WG1_SERVER_ADDRESS:-}" && -z "${WG1_CLIENT_ADDRESS:-}" ]]; then
  command -v od >/dev/null || { echo 'od is required to generate a fresh ULA prefix' >&2; exit 1; }
  ula_id="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
  ula_prefix="fd${ula_id:0:2}:${ula_id:2:4}:${ula_id:6:4}:1"
  WG1_SERVER_ADDRESS="${ula_prefix}::1/64"
  WG1_CLIENT_ADDRESS="${ula_prefix}::2/128"
  echo "Generated a fresh downstream ULA prefix: ${ula_prefix}::/64"
 elif [[ -z "${WG1_SERVER_ADDRESS:-}" || -z "${WG1_CLIENT_ADDRESS:-}" ]]; then
  echo 'Set both WG1_SERVER_ADDRESS and WG1_CLIENT_ADDRESS, or leave both blank for automatic generation.' >&2; exit 1
 fi
 cidr6 "$WG1_SERVER_ADDRESS" || { echo 'WG1_SERVER_ADDRESS must be IPv6 CIDR' >&2; exit 1; }
 cidr6 "$WG1_CLIENT_ADDRESS" || { echo 'WG1_CLIENT_ADDRESS must be IPv6 CIDR' >&2; exit 1; }
fi
command -v apt-get >/dev/null; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools
install -d -m 700 /etc/wireguard /root/route64-wg-backups
backup_dir="/root/route64-wg-backups/$(date +%Y%m%d-%H%M%S)"; mkdir -m 700 "$backup_dir"; cp -a /etc/wireguard/. "$backup_dir/" 2>/dev/null || true
make_key(){ local supplied="$1" target="$2"; if [[ -n "$supplied" ]]; then printf '%s\n' "$supplied" > "$target"; else umask 077; wg genkey > "$target"; fi; chmod 600 "$target"; }
make_key "${ROUTE64_PRIVATE_KEY:-}" /etc/wireguard/wg0.key; echo "Route64 client public key (register in the Route64 manager if this is a newly generated key):"; wg pubkey < /etc/wireguard/wg0.key; p0="$(cat /etc/wireguard/wg0.key)"
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $p0
Address = $ROUTE64_ADDRESS
MTU = ${ROUTE64_MTU:-1420}

[Peer]
PublicKey = $ROUTE64_PUBLIC_KEY
Endpoint = $ROUTE64_ENDPOINT
AllowedIPs = ${ROUTE64_ALLOWED_IPS:-::/1,8000::/1}
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf; unset p0 ROUTE64_PRIVATE_KEY
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
 make_key "${WG1_PRIVATE_KEY:-}" /etc/wireguard/wg1.key; p1="$(cat /etc/wireguard/wg1.key)"
 cat > /etc/wireguard/wg1.conf <<EOF
[Interface]
PrivateKey = $p1
Address = $WG1_SERVER_ADDRESS
ListenPort = $WG1_LISTEN_PORT
MTU = ${ROUTE64_MTU:-1420}
EOF
 if [[ -n "${WG1_CLIENT_PUBLIC_KEY:-}" ]]; then
  printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = %s' "$WG1_CLIENT_PUBLIC_KEY" "$WG1_CLIENT_ADDRESS" >> /etc/wireguard/wg1.conf
  printf ', %s' "$ROUTED_PREFIX" >> /etc/wireguard/wg1.conf
  [[ -z "${WG1_CLIENT_ALLOWED_PREFIX:-}" ]] || printf ', %s' "$WG1_CLIENT_ALLOWED_PREFIX" >> /etc/wireguard/wg1.conf
  printf '\n' >> /etc/wireguard/wg1.conf
 fi
 chmod 600 /etc/wireguard/wg1.conf; unset p1 WG1_PRIVATE_KEY
fi
sysctl -w net.ipv6.conf.all.forwarding=1; printf 'net.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/90-route64-wireguard.conf
systemctl enable --now wg-quick@wg0
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then systemctl enable --now wg-quick@wg1; fi
echo "Installed. Backup: $backup_dir"; echo 'Firewall unchanged; configure UDP ingress and IPv6 forwarding manually.'; echo 'No IPv4 routes, NAT66, or unrelated WireGuard interfaces were modified.'
