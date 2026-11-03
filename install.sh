#!/usr/bin/env bash
# Route64 WireGuard Toolkit - 中文全屏终端向导
set -Eeuo pipefail
umask 077

APP_NAME="Route64 IPv6 隧道工具"
TMP_DIR=""
UI_ACTIVE=0
BACKUP_DIR=""
WG0_CREATED=0
WG0_STARTED=0
OLD_FORWARDING=""
SYSCTL_FILE_CREATED=0

ui_enter() {
  if [[ -t 0 && -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1049h\033[?25l'
    UI_ACTIVE=1
  fi
}
ui_leave() {
  if (( UI_ACTIVE )); then
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[0m\033[?25h\033[?1049l'
    UI_ACTIVE=0
  fi
}
ui_clear() {
  if (( UI_ACTIVE )); then printf '\033[2J\033[H'; else printf '\n'; fi
}
draw_header() {
  ui_clear
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                  Route64 IPv6 隧道管理工具                          ║
║                    VPS 一键部署 · IPv6 查询                          ║
╠══════════════════════════════════════════════════════════════════════╣
║  自动读取 Route64 Linux 配置，生成 WireGuard 配置并检查 IPv6 连通性  ║
║  配置仅保存在 VPS：不会上传私钥，不会修改 IPv4 默认路由或防火墙规则  ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
}
# 全屏界面使用终端规范行模式读取输入，不逐字节解析 ANSI 控制序列。
# 关闭可能由外层终端/程序遗留的鼠标报告模式，避免滚轮事件进入 stdin。
ui_disable_mouse_reporting() {
  if (( UI_ACTIVE )); then
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l'
  fi
}

pause() {
  echo
  if (( UI_ACTIVE )); then
    printf "按回车键返回主菜单（鼠标滚轮不会触发返回）……"
    # 整行消费输入；滚轮即使被终端转成控制字符，也不会成为下一次菜单选项。
    IFS= read -r _ </dev/tty || true
    ui_disable_mouse_reporting
    printf '\033[0m\033[3J\033[2J\033[H'
  else
    read -r -p "按回车键返回主菜单..." _ || true
  fi
}
cleanup() {
  local rc=$?
  if (( rc != 0 && WG0_CREATED )); then
    echo
    echo "安装失败，正在尝试回滚本次 wg0 配置……" >&2
    if (( WG0_STARTED )); then systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true; fi
    rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg0.key
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
      cp -a "$BACKUP_DIR/." /etc/wireguard/ 2>/dev/null || true
    fi
    if (( SYSCTL_FILE_CREATED )); then rm -f /etc/sysctl.d/90-route64-wireguard.conf; fi
    if [[ -n "$OLD_FORWARDING" ]]; then
      sysctl -w "net.ipv6.conf.all.forwarding=$OLD_FORWARDING" >/dev/null 2>&1 || true
    fi
    echo "已尝试恢复配置；备份目录：${BACKUP_DIR:-无}" >&2
  fi
  [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
  ui_leave
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

need_cmd() { command -v "$1" >/dev/null 2>&1; }
install_dependencies() {
  local missing=()
  for c in wg wg-quick ip ping python3 curl systemctl; do need_cmd "$c" || missing+=("$c"); done
  if (("${#missing[@]}" > 0)); then
    [[ -n "${ID:-}" ]] || { [[ -r /etc/os-release ]] && . /etc/os-release; }
    [[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] || {
      echo "当前系统缺少依赖：${missing[*]}；仅自动支持 Ubuntu / Debian。"; return 1;
    }
    echo "正在安装缺少的组件：${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 iputils-ping python3 curl
  fi
}

query_ipv6() {
  draw_header
  echo "【IPv6 地址查询】"
  echo "正在查询 VPS 当前公网出口 IPv6……"
  local found=0 addr=""
  if need_cmd curl; then
    for url in "https://api64.ipify.org" "https://ifconfig.co/ip" "https://icanhazip.com"; do
      addr="$(curl -6 -fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -n "$addr" ]] && [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$addr" == *:* ]]; then
        printf '\n公网 IPv6：\n  %s\n' "$addr"
        found=1
        break
      fi
    done
  fi
  if (( ! found )); then
    echo "公网 IPv6 查询失败：当前出口可能没有 IPv6，或 DNS/网络/目标服务不可用。"
  fi
  echo
  echo "VPS 本机全局 IPv6 地址："
  if need_cmd ip; then
    ip -6 -o addr show scope global 2>/dev/null | awk '{print "  " $4 " (" $2 ")"}' || true
  else
    echo "  ip 命令不可用"
  fi
  echo
  echo "WireGuard 状态："
  if need_cmd wg && wg show wg0 >/dev/null 2>&1; then
    printf "  wg0：已启动\n"
    printf "  Endpoint："; wg show wg0 endpoints | awk 'NR==1 {print $2}'
    printf "  最近握手："
    hs="$(wg show wg0 latest-handshakes | awk 'NR==1 {print $2}')"
    if [[ -n "$hs" && "$hs" != 0 ]]; then date -d "@$hs" '+%F %T %Z' 2>/dev/null || echo "$hs"; else echo "尚无握手"; fi
  else
    echo "  wg0：未运行"
  fi
  pause
}

parse_route64_config() {
  local file="$1"
  python3 - "$file" <<'PY'
import base64, ipaddress, re, sys
path=sys.argv[1]
section=None
data={"Interface":{}, "Peer":{}}
for raw in open(path, encoding="utf-8-sig"):
    line=raw.strip()
    if not line or line.startswith(("#",";")):
        continue
    m=re.fullmatch(r"\[([^]]+)\]", line)
    if m:
        name=m.group(1).strip()
        section=name if name in data else None
        continue
    if section is None or "=" not in line:
        # Ignore accompanying Linux helper commands such as ip route and ping.
        continue
    key,value=line.split("=",1)
    key=key.strip()
    value=value.split("#",1)[0].split(";",1)[0].strip()
    if key in {"PrivateKey","Address","MTU"} and section=="Interface":
        data[section][key]=value
    elif key in {"PublicKey","PresharedKey","AllowedIPs","Endpoint","PersistentKeepalive"} and section=="Peer":
        data[section][key]=value

i,p=data["Interface"],data["Peer"]
addresses=[x.strip() for x in i.get("Address","").split(",")]
address=next((x for x in addresses if ":" in x), "")
if not address: raise SystemExit("配置错误：未找到 [Interface] 中的 IPv6 Address。")
try:
    if ipaddress.ip_interface(address).version != 6: raise ValueError()
except ValueError: raise SystemExit("配置错误：IPv6 Address 格式不正确。")
pub=p.get("PublicKey","")
psk=p.get("PresharedKey","")
if psk and not re.fullmatch(r"[A-Za-z0-9+/]{43}=", psk): raise SystemExit("配置错误：PresharedKey 格式不正确。")
if not re.fullmatch(r"[A-Za-z0-9+/]{43}=", pub): raise SystemExit("配置错误：[Peer] PublicKey 缺失或格式不正确。")
endpoint=p.get("Endpoint","")
if not re.fullmatch(r"(?:\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}", endpoint):
    raise SystemExit("配置错误：[Peer] Endpoint 格式不正确，应为主机名或 IP:端口。")
port=int(endpoint.rsplit(":",1)[1])
if not 1 <= port <= 65535: raise SystemExit("配置错误：Endpoint 端口超出范围。")
allowed=p.get("AllowedIPs","")
if not allowed: raise SystemExit("配置错误：[Peer] 缺少 AllowedIPs。")
for item in allowed.split(","):
    try: ipaddress.ip_network(item.strip(), strict=False)
    except ValueError: raise SystemExit("配置错误：AllowedIPs 中存在无效网段："+item.strip())
mtu=i.get("MTU","1420")
if mtu and (not mtu.isdigit() or not 576 <= int(mtu) <= 9000):
    raise SystemExit("配置错误：MTU 必须是 576–9000 之间的数字。")
keep=p.get("PersistentKeepalive","25")
if keep and (not keep.isdigit() or not 0 <= int(keep) <= 65535):
    raise SystemExit("配置错误：PersistentKeepalive 格式不正确。")
private=i.get("PrivateKey","")
if private and not re.fullmatch(r"[A-Za-z0-9+/]{43}=", private):
    raise SystemExit("配置错误：PrivateKey 格式不正确。")
values=[private,address,pub,psk,allowed,endpoint,keep or "25",mtu or "1420"]
for value in values:
    print(base64.b64encode(value.encode()).decode())
PY
}

install_tunnel() {
  draw_header
  echo "【创建 Route64 隧道】"
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行安装功能。"
    pause; return
  fi
  [[ -r /etc/os-release ]] || { echo "无法识别 Linux 系统。"; pause; return; }
  . /etc/os-release
  if [[ "${ID:-}" != ubuntu && "${ID:-}" != debian ]]; then
    echo "当前仅支持 Ubuntu / Debian，检测到：${PRETTY_NAME:-未知系统}"
    pause; return
  fi
  if [[ -e /etc/wireguard/wg0.conf ]]; then
    echo "检测到 /etc/wireguard/wg0.conf 已存在。为避免覆盖现有隧道，安装已停止。"
    pause; return
  fi
  install_dependencies || { pause; return; }
  TMP_DIR="$(mktemp -d /tmp/route64-wizard.XXXXXX)"
  chmod 700 "$TMP_DIR"
  local conf="$TMP_DIR/route64.conf"
  : > "$conf"
  echo
  echo "请粘贴 Route64 面板提供的 Linux WireGuard 配置。"
  echo "只需粘贴配置正文；附带的 ip route、ping 命令会自动忽略。"
  echo "粘贴完成后，单独输入 END 并回车。"
  echo "注意：PrivateKey 是敏感信息，请勿公开分享。"
  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    printf '%s\n' "$line" >> "$conf"
  done
  if [[ ! -s "$conf" ]]; then echo "没有读取到配置内容。"; rm -rf "$TMP_DIR"; TMP_DIR=""; pause; return; fi

  local -a parsed=()
  if ! mapfile -t parsed < <(parse_route64_config "$conf"); then
    echo "配置解析失败，请检查是否包含 [Interface] 和 [Peer]。"
    rm -rf "$TMP_DIR"; TMP_DIR=""; pause; return
  fi
  if (("${#parsed[@]}" != 8)); then
    echo "配置解析失败：提取到的字段不完整。"
    rm -rf "$TMP_DIR"; TMP_DIR=""; pause; return
  fi
  local -a values=()
  local item
  for item in "${parsed[@]}"; do values+=("$(printf '%s' "$item" | base64 -d)"); done
  local private="${values[0]}" address="${values[1]}" public="${values[2]}"
  local psk="${values[3]}"
  local allowed="${values[4]}" endpoint="${values[5]}" keepalive="${values[6]}" mtu="${values[7]}"

  draw_header
  echo "【配置识别结果】"
  printf "隧道 IPv6 地址：%s\n" "$address"
  printf "Route64 Endpoint：%s\n" "$endpoint"
  printf "AllowedIPs：%s\n" "$allowed"
  printf "保活间隔：%s 秒\n" "$keepalive"
  printf "MTU：%s\n" "$mtu"
  echo "私钥：已读取（不显示）"
  echo "对端公钥：已读取"
  [[ -z "$psk" ]] || echo "预共享密钥：已读取"
  echo
  echo "将创建 /etc/wireguard/wg0.conf，并启用 wg-quick@wg0。"
  echo "不需要手动填写 Routed Prefix，也不需要手动添加 ::/0 路由。"
  read -r -p "确认继续安装？[Y/n] " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then rm -rf "$TMP_DIR"; TMP_DIR=""; pause; return; fi

  install -d -m 700 /etc/wireguard /root/route64-wg-backups
  BACKUP_DIR="/root/route64-wg-backups/$(date +%Y%m%d-%H%M%S)-$$"
  install -d -m 700 "$BACKUP_DIR"
  cp -a /etc/wireguard/. "$BACKUP_DIR/" 2>/dev/null || true
  if [[ -z "$private" ]]; then
    echo "配置没有 PrivateKey，正在生成新密钥。"
    private="$(wg genkey)"
    echo "新生成的客户端公钥如下，请先登记到 Route64 面板，隧道才能握手："
    printf '%s\n' "$private" | wg pubkey
  fi
  WG0_CREATED=1
  printf '%s\n' "$private" > /etc/wireguard/wg0.key
  chmod 600 /etc/wireguard/wg0.key
  cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $private
Address = $address
MTU = $mtu

[Peer]
PublicKey = $public
Endpoint = $endpoint
AllowedIPs = $allowed
PersistentKeepalive = $keepalive
EOF
  if [[ -n "$psk" ]]; then sed -i "/^PublicKey = /a PresharedKey = $psk" /etc/wireguard/wg0.conf; fi
  unset private psk
  chmod 600 /etc/wireguard/wg0.conf
  if ! wg-quick strip wg0 >/dev/null; then
    echo "WireGuard 配置校验失败，未启动隧道。"
    rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg0.key
    WG0_CREATED=0
    rm -rf "$TMP_DIR"; TMP_DIR=""; pause; return
  fi

  echo
  echo "正在启动 WireGuard 隧道……"
  WG0_STARTED=1
  systemctl enable --now wg-quick@wg0
  echo
  echo "【安装结果】"
  systemctl is-active wg-quick@wg0 || true
  echo "wg0 IPv6 地址："
  ip -6 -o addr show dev wg0 2>/dev/null || true
  echo "IPv6 路由（wg0 相关）："
  ip -6 route show table all | grep -E 'wg0|::/1|8000::/1' || true
  echo "WireGuard 握手："
  wg show wg0 latest-handshakes || true
  echo
  echo "正在测试经 wg0 访问 IPv6……"
  if ping -6 -n -I wg0 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1; then
    echo "IPv6 隧道连通性：通过"
  else
    echo "IPv6 探测未通过。先检查 Route64 面板是否登记了上面显示的客户端公钥，以及 Endpoint/UDP 连通性。"
  fi
  echo "经 wg0 查询公网 IPv6："
  public_v6="$(curl -6 --interface wg0 -fsS --connect-timeout 4 --max-time 8 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$public_v6" =~ ^[0-9A-Fa-f:]+$ && "$public_v6" == *:* ]]; then
    echo "  $public_v6"
  else
    echo "  查询失败（可能尚未完成握手或 IPv6 出口不可用）。"
  fi
  echo
  echo "配置文件：/etc/wireguard/wg0.conf"
  echo "私钥文件：/etc/wireguard/wg0.key（权限 600）"
  echo "备份目录：$BACKUP_DIR"
  echo "提示：AllowedIPs 的 ::/1 和 8000::/1 会由 wg-quick 自动建立分流默认路由；"
  echo "不会照抄配置注释中的示例接口名，也不会重复添加冲突的 ::/0 路由。"
  rm -rf "$TMP_DIR"; TMP_DIR=""
  pause
}

main_menu() {
  ui_enter
  while true; do
    draw_header
    cat <<'EOF'

  [1] 创建 / 安装 Route64 IPv6 隧道
  [2] 查询 VPS 当前公网 IPv6 地址
  [3] 查看 WireGuard 与 IPv6 状态
  [0] 退出

EOF
    if (( UI_ACTIVE )); then
      # 规范模式整行读取：只接受单独输入的 0/1/2/3，滚轮控制字符不会串入下一轮。
      read -r -p "请选择功能 [0-3]：" choice </dev/tty || break
      [[ "$choice" =~ ^[0-3]$ ]] || { echo "请输入单独的 0、1、2 或 3，然后按回车。"; sleep 1; continue; }
    else
      read -r -p "请选择功能 [0-3]：" choice || break
    fi
    case "$choice" in
      1) install_tunnel ;;
      2) query_ipv6 ;;
      3)
        draw_header
        echo "【WireGuard / IPv6 状态】"
        if need_cmd wg; then wg show all || true; else echo "未安装 wireguard-tools"; fi
        echo
        if need_cmd ip; then
          echo "IPv6 地址："; ip -6 addr show scope global || true
          echo; echo "IPv6 路由："; ip -6 route show || true
        else echo "未安装 iproute2"; fi
        pause ;;
      0) break ;;
      *) echo "无效选项。"; sleep 1 ;;
    esac
  done
  ui_leave
}

if [[ "${1:-}" == "--query-ipv6" ]]; then ui_enter; query_ipv6; ui_leave; exit 0; fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "用法：sudo bash install.sh（进入中文全屏菜单）"
  echo "      bash install.sh --query-ipv6（查询公网 IPv6）"
  exit 0
fi
if (($#)); then echo "未知参数：$*"; exit 2; fi
main_menu
