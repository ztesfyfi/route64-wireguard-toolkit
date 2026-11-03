#!/usr/bin/env bash
set -u
REPORT="${1:-route64-diagnostic-$(date +%Y%m%d-%H%M%S).txt}"
exec > >(tee "$REPORT") 2>&1
section(){ printf '\n===== %s =====\n' "$1"; }
run(){ echo "+ $*"; "$@" 2>&1 || echo "[exit=$?]"; }
echo 'Route64 WireGuard read-only diagnostic'; date -Is 2>/dev/null || date; hostname; uname -a; echo 'Private keys are not intentionally printed.'
section 'OS'; [[ -r /etc/os-release ]] && cat /etc/os-release
section 'Tools'; for c in wg ip sysctl nft ip6tables iptables ss tcpdump; do command -v "$c" || true; done
section 'WireGuard'; if command -v wg >/dev/null; then wg show all; echo '-- latest handshakes (unix time)'; wg show all latest-handshakes; echo '-- transfer counters'; wg show all transfer; else echo 'wireguard-tools missing'; fi
section 'Basic connectivity probes'
if command -v ping >/dev/null; then
  echo '-- IPv4 external probe (1.1.1.1)'; ping -4 -n -c 2 -W 2 1.1.1.1 || true
  echo '-- IPv6 default-route probe (Cloudflare DNS)'; ping -6 -n -c 2 -W 3 2606:4700:4700::1111 || true
  for iface in wg0 wg2; do
    if ip link show dev "$iface" >/dev/null 2>&1; then
      echo "-- IPv6 probe bound to $iface"; ping -6 -n -I "$iface" -c 2 -W 3 2606:4700:4700::1111 || true
    fi
  done
else
  echo 'ping command missing; install iputils-ping for active connectivity probes.'
fi
echo '-- route lookup'; ip -6 route get 2606:4700:4700::1111 2>&1 || true
section 'WireGuard configs (keys redacted)'; for f in /etc/wireguard/*.conf; do [[ -f "$f" ]] || continue; echo "--- $f"; sed -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*).*/\1[REDACTED]/I' "$f"; done
section 'IPv6 addresses, rules, routes'; run ip -6 address show; run ip -6 rule show; run ip -6 route show table all
section 'IPv4 routes'; run ip -4 route show
section 'Forwarding and RA'; for k in net.ipv6.conf.all.forwarding net.ipv6.conf.default.forwarding net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra; do sysctl "$k" 2>&1 || true; done
section 'Firewall'; command -v nft >/dev/null && run nft list ruleset; command -v ip6tables >/dev/null && run ip6tables -S; command -v ip6tables >/dev/null && run ip6tables -L FORWARD -n -v; command -v iptables >/dev/null && run iptables -L FORWARD -n -v
section 'Services and UDP listeners'; systemctl --no-pager --full status wg-quick@wg0 wg-quick@wg1 wg-quick@wg2 route64-failover 2>&1 || true; [[ ! -r /run/route64-failover.active ]] || { echo 'Active Route64 uplink:'; cat /run/route64-failover.active; }; command -v ss >/dev/null && run ss -lunp
echo; echo "Report saved: $REPORT"; echo 'Read-only: no configuration changed. Redact public IPs/hostnames before sharing.'
