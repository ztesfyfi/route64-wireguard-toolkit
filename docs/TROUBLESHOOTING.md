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


## 地址配置错误或疑似使用了旧地址

- 不要从旧 VPS、旧隧道或旧客户端配置复制 `ROUTE64_ADDRESS`、`ROUTED_PREFIX`、`ROUTE64_ENDPOINT`。
- 重新从当前 Route64 管理面板导出/查看当前隧道的 WireGuard 配置，核对隧道地址、对端公钥和 Endpoint。
- `ROUTED_PREFIX` 应核对当前隧道分配的前缀，不要把隧道传输网段误填为路由前缀。
- 启用下游 wg1 时，服务器和客户端 ULA 地址可以同时留空，由安装脚本生成新的随机 ULA 前缀；如果手动填写，必须成对填写。
- 如果地址来源不确定、格式不合法，或与 VPS 现有路由/接口冲突，先停止安装并确认，不要尝试用猜测的 IP 继续部署。

Route64 分配的传输地址和路由前缀不能从 VPS 本机可靠推算。请以当前 Route64 管理面板为准。


## 使用配置导入助手

建议从当前 Route64 管理面板重新下载 WireGuard 配置，再执行：

```bash
bash configure.sh /path/to/current-route64.conf
```

助手会从该配置读取隧道地址、对端公钥、Endpoint、AllowedIPs 和 MTU，并要求你输入当前隧道分配的路由前缀。它不会覆盖已有的 `config/config.env`。生成后请检查配置文件，尤其确认路由前缀来自当前隧道。

如果导出的配置没有 PrivateKey，助手会保留空值；此时需要先生成本机密钥，并将对应公钥登记到 Route64，不能直接期待隧道握手成功。


## 下游 WireGuard 端口冲突或无法连接

- `WG1_LISTEN_PORT` 留空时，安装脚本会从 UDP 高位端口范围 `49152-65535` 中随机挑选，并尝试绑定检查端口是否可用。
- 也可以手动指定该范围内的端口；若端口已被占用或无法绑定，安装会中止。
- 安装输出会显示最终端口。请将该 UDP 端口放行于 VPS 防火墙和云厂商安全组。
- 端口检测是在安装时进行的短暂绑定测试，测试结束后才由 WireGuard 接管；若其他程序随后抢占端口，仍可能发生冲突。


## 双隧道自动切换故障排查

- 检查 `sudo systemctl status wg-quick@wg0 wg-quick@wg2 route64-failover`。
- 查看控制器日志：`sudo journalctl -u route64-failover -n 100 --no-pager`。
- 查看当前选中的上游：`cat /run/route64-failover.active`。
- 分别测试两条隧道：`ping -6 -I wg0 -c 3 2606:4700:4700::1111` 和 `ping -6 -I wg2 -c 3 2606:4700:4700::1111`。
- 检查 `wg0.conf`、`wg2.conf` 的 `[Interface]` 段都设置了 `Table = off`。否则 wg-quick 自己创建的策略路由可能与控制器冲突。
- 检查主路由表：`ip -6 route show`。控制器管理 `::/1` 和 `8000::/1` 两条路由。
- 确认探测目标允许 ICMPv6；目标屏蔽 ping 会导致误判为隧道故障，可在 `/etc/default/route64-failover` 中更换 `PROBE_TARGET`。
- 如果两条隧道都探测失败，控制器会保留最后一次路由，不会声称已有可用出口。

### 下游公网前缀切换失败

控制器只切换 VPS 的 IPv6 出口路由。下游 wg1 使用的 Route64 Routed Prefix 是否能从备用隧道回程，取决于 Route64 是否允许该前缀经备用隧道路由。必须在 Route64 面板/服务端侧确认两条隧道的前缀路由关系；仅切换 VPS 默认路由不能保证下游公网入站可用。

### 停止控制器

```bash
sudo systemctl disable --now route64-failover
```

停止控制器不会自动恢复此前的路由策略。停止前请确认当前 IPv6 路由符合你的预期。
