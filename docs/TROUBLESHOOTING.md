# Troubleshooting

Run `sudo bash diagnose.sh` first. It is read-only and writes a local report.

## No recent handshake
- Check peer endpoint, UDP port, and public keys.
- Permit the WireGuard UDP port in cloud and host firewalls.
- Inspect `wg show`, `ss -lunp`, and `sudo tcpdump -ni any udp port PORT`.

## Handshake works, IPv6 does not
1. Check `sysctl net.ipv6.conf.all.forwarding` (must be 1 for routing).
2. Inspect `ip -6 route show table all` and `ip -6 rule show`.
3. Verify peer AllowedIPs includes the prefixes that must traverse that peer.
4. Inspect nftables/iptables FORWARD policy and counters.
5. Capture on both interfaces: `tcpdump -ni wg1 ip6` and `tcpdump -ni wg0 ip6`.

## Routed prefix and return path
- VPS peer for a downstream client must include its tunnel address and routed prefix in AllowedIPs.
- VPS must route the delegated prefix via the downstream interface.
- Route64 must route the delegated prefix to the VPS Route64 tunnel/client as specified by Route64.
- Permit forwarding in both directions. Do not use NAT66 for routed public IPv6.

## Forwarding and RA
Enabling IPv6 forwarding can change Router Advertisement acceptance. If the VPS obtains its IPv6 default route by RA, inspect `net.ipv6.conf.IFACE.accept_ra`. Setting it to 2 may be required on that specific interface; identify the actual uplink first.

## MTU and packet loss
Compare MTU at both ends, test smaller IPv6 payloads, and ensure essential ICMPv6 (especially Packet Too Big) is not blocked.

Never share private keys, preshared keys, tokens, or unredacted config files. The installer refuses to overwrite existing wg0.conf/wg1.conf and intentionally leaves firewall policy to the administrator.
