#!/usr/bin/env bash
set -Eeuo pipefail
TMP_DIR=""
UI_ACTIVE=0
ui_enter(){
  if [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; then
    printf '\033[?1049h\033[?25l'
    UI_ACTIVE=1
  fi
}
ui_leave(){
  if (( UI_ACTIVE )); then
    printf '\033[?0m\033[?25h\033[?1049l'
    UI_ACTIVE=0
  fi
}
ui_page(){
  if (( UI_ACTIVE )); then printf '\033[2J\033[H'; fi
  cat <<'EOF'
┌──────────────────────────────────────────────────────────────────────┐
│                 Route64 WireGuard 一键部署工具                       │
│                         交互式安装向导                                │
├──────────────────────────────────────────────────────────────────────┤
│  本工具将自动检查环境、导入配置、生成密钥、安装隧道并执行连通性检测。 │
│                                                                      │
│  安全说明：不会覆盖已有 wg0/wg1，不会修改 SSH 和 IPv4 默认路由。     │
│  需要你提供 Route64 当前隧道配置及该隧道分配的 Routed Prefix。       │
└──────────────────────────────────────────────────────────────────────┘
EOF
}
BACKUP_READY=0
WG0_STARTED=0
WG1_STARTED=0
WG0_CREATED=0
WG1_CREATED=0
SYSCTL_OLD=""
SYSCTL_CREATED=0
backup_dir=""

cleanup(){
  local rc=$?
  if (( rc != 0 && BACKUP_READY )); then
    echo "Installation failed; attempting rollback..." >&2
    if (( WG1_STARTED )); then systemctl disable --now wg-quick@wg1 >/dev/null 2>&1 || true; fi
    if (( WG0_STARTED )); then systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true; fi
    if (( WG0_CREATED )); then rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg0.key; fi
    if (( WG1_CREATED )); then rm -f /etc/wireguard/wg1.conf /etc/wireguard/wg1.key; fi
    cp -a "$backup_dir/." /etc/wireguard/ 2>/dev/null || true
    if (( SYSCTL_CREATED )); then rm -f /etc/sysctl.d/90-route64-wireguard.conf; fi
    if [[ -n "$SYSCTL_OLD" ]]; then sysctl -w "net.ipv6.conf.all.forwarding=$SYSCTL_OLD" >/dev/null 2>&1 || true; fi
    echo "Rollback attempted. Backup: $backup_dir" >&2
  fi
  [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
  ui_leave
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

CONFIG=""
while (($#)); do case "$1" in --config) [[ $# -ge 2 ]] || { echo 'Missing config path' >&2; exit 2; }; CONFIG="$2"; shift 2;; -h|--help) echo 'Usage: sudo bash install.sh [--config PATH]'; exit 0;; *) echo "Unknown argument: $1" >&2; exit 2;; esac; done
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -r /etc/os-release ]] || { echo 'Cannot identify Linux distribution.' >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] || { echo "Unsupported OS: ${PRETTY_NAME:-unknown}; Ubuntu/Debian only." >&2; exit 1; }
if [[ -z "$CONFIG" ]]; then
  command -v curl >/dev/null 2>&1 || { echo '需要 curl 才能使用在线交互安装。' >&2; exit 1; }
  ui_enter
  ui_page
  TMP_DIR="$(mktemp -d /tmp/route64-wizard.XXXXXX)"
  chmod 700 "$TMP_DIR"
  ROUTE_CONF="$TMP_DIR/route64.conf"
  : > "$ROUTE_CONF"
  echo
  echo "【第 1 步 / 4】粘贴 Route64 导出的完整 WireGuard 配置"
  echo "配置必须包含 [Interface] 和 [Peer] 两个部分。"
  echo "粘贴结束后，另起一行输入 END 并回车。"
  echo "提示：配置中的 PrivateKey 属于敏感信息，请勿公开。"
  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    printf '%s\\n' "$line" >> "$ROUTE_CONF"
  done
  [[ -s "$ROUTE_CONF" ]] || { echo "错误：没有收到配置内容。" >&2; exit 1; }

  echo
  echo "【第 2 步 / 4】输入当前隧道的 Routed Prefix"
  echo "请从 Route64 面板复制分配给这条隧道的路由前缀，例如实际分配的 /56。"
  echo "注意：这里不是 [Interface] 中的隧道地址。"
  read -r -p "Routed Prefix： " ROUTED_PREFIX
  [[ -n "$ROUTED_PREFIX" ]] || { echo "错误：Routed Prefix 不能为空。" >&2; exit 1; }

  echo
  echo "正在下载配置验证模块……"
  if ! curl -fsSL "https://raw.githubusercontent.com/ztesfyfi/route64-wireguard-toolkit/main/configure.sh" -o "$TMP_DIR/configure.sh"; then
    echo "下载失败：无法访问 raw.githubusercontent.com。请检查 VPS DNS 和网络后重试。" >&2
    exit 1
  fi
  bash "$TMP_DIR/configure.sh" "$ROUTE_CONF" -o "$TMP_DIR/config.env" --routed-prefix "$ROUTED_PREFIX"
  CONFIG="$TMP_DIR/config.env"
fi
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo 'Config file missing. Use --config PATH or interactive mode.' >&2; exit 1; }
chmod 600 "$CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"
if [[ -z "${CONFIG:-}" || "$CONFIG" == "$TMP_DIR/config.env" ]]; then
  echo
  echo "【第 3 步 / 4】下游 WireGuard 设置"
  read -r -p "是否同时创建下游 WireGuard 服务端 wg1？[y/N]：" answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    ENABLE_DOWNSTREAM_WG1=yes
    read -r -p "客户端公钥（暂时没有可留空，之后可手动添加）：" WG1_CLIENT_PUBLIC_KEY
  else
    ENABLE_DOWNSTREAM_WG1=no
  fi
fi
need(){ [[ -n "${!1:-}" ]] || { echo "Missing config value: $1" >&2; exit 1; }; }
cidr6(){ [[ "$1" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]]; }
need ROUTE64_PUBLIC_KEY; need ROUTE64_ENDPOINT; need ROUTE64_ADDRESS; need ROUTED_PREFIX
cidr6 "$ROUTE64_ADDRESS" || { echo 'ROUTE64_ADDRESS must be IPv6 CIDR' >&2; exit 1; }
cidr6 "$ROUTED_PREFIX" || { echo 'ROUTED_PREFIX must be IPv6 CIDR' >&2; exit 1; }
[[ ! -e /etc/wireguard/wg0.conf ]] || { echo 'Refusing to overwrite existing wg0.conf' >&2; exit 1; }
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
 [[ ! -e /etc/wireguard/wg1.conf ]] || { echo 'Refusing to overwrite existing wg1.conf' >&2; exit 1; }
 if [[ -n "${WG1_LISTEN_PORT:-}" ]]; then
  [[ "$WG1_LISTEN_PORT" =~ ^[0-9]{1,5}$ ]] && ((WG1_LISTEN_PORT>=49152 && WG1_LISTEN_PORT<=65535)) || { echo 'WG1_LISTEN_PORT must be an unprivileged high port (49152-65535), or blank for automatic selection.' >&2; exit 1; }
 fi
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
command -v apt-get >/dev/null || { echo 'apt-get is required on Ubuntu/Debian.' >&2; exit 1; }
if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1 || ! command -v ping >/dev/null 2>&1; then
  echo "Installing missing system dependencies..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools python3 iproute2 iputils-ping
fi
python3 - "$ROUTE64_ADDRESS" "$ROUTED_PREFIX" <<'PY'
import ipaddress, sys
try:
    address = ipaddress.ip_interface(sys.argv[1])
    prefix = ipaddress.ip_network(sys.argv[2], strict=False)
    if address.version != 6 or prefix.version != 6:
        raise ValueError("IPv6 values are required")
except Exception as exc:
    raise SystemExit(f"Invalid Route64 IPv6 address/prefix: {exc}")
PY
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
 WG1_LISTEN_PORT="$(python3 - "${WG1_LISTEN_PORT:-}" <<'PY'
import secrets, socket, sys
requested = sys.argv[1].strip()
def available(port):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        sock.bind(("::", port))
        return True
    except OSError:
        return False
    finally:
        sock.close()
if requested:
    port = int(requested)
    if not available(port):
        raise SystemExit(f"UDP port {port} is already in use or cannot be bound; choose another port.")
else:
    candidates = list(range(49152, 65536))
    secrets.SystemRandom().shuffle(candidates)
    port = next((p for p in candidates if available(p)), None)
    if port is None:
        raise SystemExit("No available UDP high port found in range 49152-65535.")
print(port)
PY
 )"
 echo "Selected downstream WireGuard UDP port: $WG1_LISTEN_PORT"
fi
install -d -m 700 /etc/wireguard /root/route64-wg-backups
[[ ! -e /etc/sysctl.d/90-route64-wireguard.conf ]] || { echo 'Refusing to overwrite existing /etc/sysctl.d/90-route64-wireguard.conf' >&2; exit 1; }
SYSCTL_OLD="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"
backup_dir="/root/route64-wg-backups/$(date +%Y%m%d-%H%M%S)-$"
mkdir -m 700 "$backup_dir"
cp -a /etc/wireguard/. "$backup_dir/" 2>/dev/null || true
BACKUP_READY=1
make_key(){ local supplied="$1" target="$2"; if [[ -n "$supplied" ]]; then printf '%s\n' "$supplied" > "$target"; else umask 077; wg genkey > "$target"; fi; chmod 600 "$target"; }
WG0_CREATED=1
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
# Parse generated configs before changing sysctl or starting services.
wg-quick strip wg0 >/dev/null || { echo "Generated wg0.conf failed WireGuard validation." >&2; exit 1; }
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
 WG1_CREATED=1
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
 wg-quick strip wg1 >/dev/null || { echo "Generated wg1.conf failed WireGuard validation." >&2; exit 1; }
fi
sysctl -w net.ipv6.conf.all.forwarding=1
printf 'net.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/90-route64-wireguard.conf
SYSCTL_CREATED=1
WG0_STARTED=1
systemctl enable --now wg-quick@wg0
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
  WG1_STARTED=1
  systemctl enable --now wg-quick@wg1
fi
echo
echo "【第 4 步 / 4】部署完成，正在进行最后检查"
echo "配置备份位置：$backup_dir"
echo
echo "===== 安装后自动检测 ====="
printf 'wg0 service: '; systemctl is-active wg-quick@wg0 || true
printf 'IPv6 forwarding: '; sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || true
printf 'wg0 peer handshake timestamp: '
handshake="$(wg show wg0 latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
if [[ -n "$handshake" && "$handshake" != 0 ]]; then
  date -d "@$handshake" '+%F %T %Z' 2>/dev/null || printf '%s\n' "$handshake"
else
  echo "NONE"
  echo "WARNING: no successful handshake detected yet."
  echo "Check Route64 client public-key registration, endpoint, UDP egress and peer keys."
fi
printf 'IPv6 probe through wg0: '
if ping -6 -n -I wg0 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1; then
  echo "PASS"
else
  echo "FAILED"
  echo "Check handshake first, then AllowedIPs, Route64 routing, MTU and ICMPv6 filtering."
fi
if [[ "${ENABLE_DOWNSTREAM_WG1:-no}" == yes ]]; then
  printf 'wg1 service: '; systemctl is-active wg-quick@wg1 || true
  printf 'wg1 listen port: '; wg show wg1 listen-port 2>/dev/null || true
  echo "Reminder: allow this UDP port in both the cloud security group and VPS firewall."
fi
echo
echo "防火墙规则未自动修改；未更改 IPv4 路由、NAT66 或其他 WireGuard 接口。"
echo "如检测未通过，请根据上方提示检查 Route64 公钥登记、对端和 UDP 连通性。"
