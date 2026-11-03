# Route64 WireGuard 工具包

用于在 VPS 端部署和诊断 Route64 IPv6 隧道，以及可选的下游 WireGuard 对等连接。

**项目范围：仅支持 Ubuntu / Debian VPS。** 本项目不负责配置 OpenWrt、iStoreOS、Open-Box、局域网路由器通告（RA），也不会配置客户端设备。

## 文件说明

- `install.sh`：部署 Route64 的 `wg0`，并可选择部署下游 WireGuard 接口 `wg1`。
- `diagnose.sh`：只读诊断 WireGuard、IPv6 路由与规则、IPv6 转发、防火墙和相关服务状态。
- `config/config.example`：配置文件模板；下游 ULA 地址默认留空，由安装时随机生成。
- `docs/TROUBLESHOOTING.md`：常见故障的检查方法。

## 快速开始

1. 将 `config/config.example` 复制为 `config/config.env`，并根据 Route64 控制面板填写配置。
2. 设置配置文件权限：
   ```bash
   chmod 600 config/config.env
   ```
3. 检查安装脚本内容，确认理解其操作后再执行：
   ```bash
   sudo bash install.sh --config config/config.env
   ```
4. 部署后运行诊断脚本：
   ```bash
   sudo bash diagnose.sh
   ```

## 安装脚本行为与注意事项

安装脚本需要以 root 权限运行。如果检测到以下配置文件已经存在，脚本会拒绝覆盖：

- `/etc/wireguard/wg0.conf`
- `/etc/wireguard/wg1.conf`（仅在启用下游 wg1 时检查）

脚本会将已有的 WireGuard 文件备份到：

```text
/root/route64-wg-backups/
```

脚本会启用 IPv6 转发，但**不会**执行以下操作：

- 清空或重写现有防火墙规则；
- 修改 IPv4 路由；
- 配置 NAT66；
- 修改其他无关的 WireGuard 接口。

防火墙规则不会由脚本自动配置。请根据 VPS 当前使用的 nftables / iptables 规则，自行确认已放行所需的 UDP 监听端口，并允许必要的 IPv6 转发流量。

## IP 地址获取与部署前确认

本工具不沿用历史测试环境中的 VPS、隧道或客户端 IP。配置模板中的 Route64 地址和前缀均为空，必须以**当前 Route64 管理面板为准**，不要复制旧机器或旧隧道的配置。

- `ROUTE64_ADDRESS`、`ROUTE64_PUBLIC_KEY`、`ROUTE64_ENDPOINT`：从当前 Route64 隧道生成的 WireGuard 配置中取得。
- `ROUTED_PREFIX`：从当前 Route64 管理面板取得分配给该隧道的路由前缀。
- 可选下游 `wg1` 的服务器和客户端 ULA 地址：配置模板默认留空。启用 wg1 时，安装脚本会生成一个新的随机 ULA 前缀和对应地址，不再使用固定的示例地址。若手动填写，则必须同时填写服务器地址和客户端地址。
- VPS 当前公网出口地址、网卡和路由属于运行环境信息，不能拿旧记录代替。安装前应在目标 VPS 上重新检查。

Route64 的隧道地址和路由前缀由 Route64 分配，不能仅凭 VPS 本机信息可靠推算；如果当前面板没有提供可用的配置导出/API，就必须由用户从当前面板确认，脚本不会猜测或套用旧值。

## 配置说明

- `ROUTE64_ALLOWED_IPS` 默认值为 `::/1,8000::/1`。使用前请对照 Route64 控制面板确认是否适合你的隧道配置。
- `ROUTED_PREFIX` 表示由 VPS 路由转发的 IPv6 前缀，不是 WireGuard 隧道接口地址。
- 可选的 `wg1` 用于连接下游 WireGuard 客户端。启用并配置客户端公钥后，当前 `ROUTED_PREFIX` 会加入该客户端 Peer 的 `AllowedIPs`。脚本不会替下游客户端安装配置，也不会配置局域网 RA / SLAAC。

## 安全提示

- 不要公开私钥（PrivateKey）、预共享密钥（PresharedKey）或未脱敏的完整配置文件。
- 诊断脚本为只读脚本，不会主动修改系统配置。
- 诊断报告仍可能包含公网 IP、主机名、路由和网络结构等信息。分享报告前，请先检查并按需脱敏。
- 执行安装前，请先检查配置文件和脚本内容，并确认 VPS 上没有需要保留且会与本工具冲突的 WireGuard 配置。

## 免责声明

本工具用于辅助部署和故障诊断，不保证适用于所有 VPS 网络环境或 Route64 配置。请先备份重要配置，并在了解脚本行为后再执行。