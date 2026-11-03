# Route64 WireGuard Toolkit

VPS-side deployment and diagnostics for Route64 IPv6 tunnels and optional downstream WireGuard peers. Scope: Ubuntu/Debian VPS only; this project does not configure OpenWrt/iStoreOS, Open-Box, LAN router advertisements, or client devices.

## Files
- `install.sh`: conservative setup of Route64 wg0 and optional downstream wg1.
- `diagnose.sh`: read-only diagnostics for WireGuard, IPv6 routes/rules, forwarding, firewall, and services.
- `config/config.example`: configuration template.
- `docs/TROUBLESHOOTING.md`: common failure checks.

## Quick start
1. Copy `config/config.example` to `config/config.env` and fill values from the Route64 panel.
2. Run `chmod 600 config/config.env`.
3. Review the script, then run `sudo bash install.sh --config config/config.env`.
4. Run `sudo bash diagnose.sh`.

The installer requires root and refuses to overwrite existing `/etc/wireguard/wg0.conf` or `wg1.conf`. It backs up existing WireGuard files under `/root/route64-wg-backups/`, enables IPv6 forwarding, and does not flush firewall rules, change IPv4 routes, configure NAT66, or touch unrelated WireGuard interfaces. Firewall rules are intentionally not automated: allow the selected UDP port and IPv6 forwarding according to your own nftables/iptables policy.

`ROUTE64_ALLOWED_IPS` defaults to `::/1,8000::/1`; confirm this against your Route64 panel. `ROUTED_PREFIX` is the prefix routed to your VPS, not the tunnel interface address. The optional wg1 peer is for a downstream WireGuard client; it does not configure that client or LAN RA/SLAAC.

Never share private keys, preshared keys, or unredacted config files. The diagnostic script redacts key lines and makes no changes.
