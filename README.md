# Route64 WireGuard 工具包

用于在 VPS 端部署和诊断 Route64 IPv6 隧道，以及可选的下游 WireGuard 对等连接和双上游隧道故障切换。

**项目范围：仅支持 Ubuntu / Debian VPS。** 本项目不负责配置 OpenWrt、iStoreOS、Open-Box、局域网路由器通告（RA），也不会配置客户端设备。

## 功能

- 部署 Route64 主隧道 `wg0`。
- 可选部署下游 WireGuard 服务端 `wg1`。
- 下游 UDP 端口可自动选择未占用的高位端口（49152–65535）。
- 双 Route64 上游隧道健康检测和主备切换控制器（主隧道 `wg0`，备用隧道 `wg2`）。
- 只读网络诊断脚本。

> 双隧道控制器是独立模块。它不会自动向 Route64 申请第二条隧道，也不会自动生成第二条隧道的 Route64 配置；两条隧道必须先分别在 Route64 面板创建并配置到 VPS。

## 文件说明

- `configure.sh`：导入当前 Route64 面板导出的 WireGuard 配置，辅助生成单隧道安装配置。
- `install.sh`：部署 Route64 的 `wg0`，并可选择部署下游 WireGuard 接口 `wg1`。
- `diagnose.sh`：只读诊断 WireGuard、IPv6 路由与规则、IPv6 转发、防火墙和相关服务状态。
- `config/config.example`：单隧道安装配置模板。
- `failover/route64-failover.sh`：双上游健康检测和切换守护脚本。
- `failover/route64-failover.service`：systemd 服务单元。
- `failover/route64-failover.env.example`：主备接口和检测参数模板。
- `docs/TROUBLESHOOTING.md`：常见故障检查方法。

## 单隧道部署方法

以下示例适用于 Ubuntu / Debian VPS。建议先备份现有 WireGuard 配置，并确认 VPS 没有需要保留的同名接口。

1. 安装基础工具并下载项目：

   ```bash
   sudo apt-get update
   sudo apt-get install -y git wireguard-tools
   git clone https://github.com/ztesfyfi/route64-wireguard-toolkit.git
   cd route64-wireguard-toolkit
   ```

2. 从当前 Route64 管理面板下载该隧道的 WireGuard `.conf` 文件，然后导入：

   ```bash
   bash configure.sh /你的文件路径/route64.conf
   ```

   按提示输入**当前这条隧道**分配的路由前缀。脚本会生成权限为 `600` 的 `config/config.env`，不会覆盖已有文件。

3. 检查 `config/config.env`，确认地址、Endpoint、公钥和路由前缀都来自当前隧道。需要下游客户端时，再按需设置 `ENABLE_DOWNSTREAM_WG1="yes"` 并填写客户端公钥；不启用则保持 `no`。

4. 执行安装：

   ```bash
   sudo bash install.sh --config config/config.env
   ```

5. 部署后检查：

   ```bash
   sudo bash diagnose.sh
   sudo wg show
   ip -6 route
   ```

**说明：** 当前安装脚本要求已有配置文件。下面这条不带参数的远程命令目前不支持，不能当作一键交互安装命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ztesfyfi/route64-wireguard-toolkit/main/install.sh)
```

也可以在仓库目录中下载并执行安装脚本：

```bash
curl -fsSLO https://raw.githubusercontent.com/ztesfyfi/route64-wireguard-toolkit/main/install.sh
sudo bash install.sh --config config/config.env
```

首次部署前请检查脚本和配置；不要把包含私钥的配置文件公开。

## 双 Route64 隧道自动故障切换

### 工作原理与前置条件

控制器默认把 `wg0` 作为主隧道、`wg2` 作为备用隧道。每轮分别通过指定接口向 IPv6 探测目标发送 ICMPv6，只有实际探测成功才视为健康；连续失败达到阈值后切换，主隧道连续恢复成功达到阈值后自动切回。

启用前必须满足：

1. 在同一个 Route64 账号下创建两条独立隧道（是否允许及数量以 Route64 账号/面板限制为准），分别下载两份**当前** WireGuard 配置。
2. 两条隧道使用各自的私钥、公钥、传输地址和 Endpoint，不能把 A 隧道的密钥或地址复制给 B 隧道。
3. 在 VPS 上分别配置为 `wg0` 和 `wg2`，并在两份配置的 `[Interface]` 段加入：
   `Table = off`
   这会禁止 `wg-quick` 为两条上游隧道各自安装冲突的默认路由；默认 IPv6 路由由本控制器统一管理。
4. 两条接口的 `[Peer]` 均需包含可供探测目标使用的 IPv6 路由（常见为 `AllowedIPs = ::/1, 8000::/1`，以 Route64 当前配置为准）。
5. 两条接口都应能独立完成 WireGuard 握手，并分别通过接口绑定的 IPv6 探测。VPS 防火墙、上游网络和 Route64 侧必须允许相应流量。

**重要：** 当前 `install.sh` 只负责创建 `wg0` 和可选 `wg1`，不会自动创建第二条 Route64 隧道 `wg2`。请先按 Route64 提供的第二份配置单独创建 `/etc/wireguard/wg2.conf`，并确认 `wg-quick@wg2` 可以正常启动。不要直接覆盖现有 `wg0.conf`；修改现有配置前请备份，并确保有 VPS 控制台/救援访问方式。

### 配置与启动控制器

在仓库根目录执行：

```bash
sudo install -d -m 755 /usr/local/sbin
sudo install -m 755 failover/route64-failover.sh /usr/local/sbin/route64-failover
sudo install -m 644 failover/route64-failover.service /etc/systemd/system/route64-failover.service
sudo install -m 600 failover/route64-failover.env.example /etc/default/route64-failover
sudo nano /etc/default/route64-failover
```

默认参数如下，可按需修改：

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `PRIMARY_IFACE` | `wg0` | 主隧道接口 |
| `BACKUP_IFACE` | `wg2` | 备用隧道接口 |
| `PROBE_TARGET` | `2606:4700:4700::1111` | IPv6 连通性探测目标 |
| `CHECK_INTERVAL` | `10` | 每轮检测间隔（秒） |
| `FAIL_THRESHOLD` | `3` | 连续失败多少轮后切换 |
| `RECOVER_THRESHOLD` | `5` | 主隧道连续成功多少轮后切回 |
| `PING_COUNT` | `2` | 每轮每条隧道发送的探测包数 |
| `PING_TIMEOUT` | `3` | 单个 ping 等待超时（秒） |

启动两条上游隧道并启用控制器：

```bash
sudo systemctl enable --now wg-quick@wg0
sudo systemctl enable --now wg-quick@wg2
sudo systemctl daemon-reload
sudo systemctl enable --now route64-failover
```

查看运行状态和切换日志：

```bash
sudo systemctl status route64-failover
sudo journalctl -u route64-failover -f
cat /run/route64-failover.active
ip -6 route
```

停止自动切换：

```bash
sudo systemctl disable --now route64-failover
```

控制器通过 `ip -6 route` 管理主路由表中的 `::/1` 和 `8000::/1` 两条 IPv6 路由。请勿同时运行其他会管理这两条路由的策略路由/多出口程序，否则可能互相覆盖。

### 下游前缀与回程路由限制

本控制器切换的是 VPS 的 IPv6 出口路由。它**不会**自动把同一个 Route64 Routed Prefix 从主隧道迁移到备用隧道，也不会修改 Route64 面板中的路由归属。

如果下游 `wg1` 使用 Route64 分配的公网 IPv6 前缀，要实现主隧道故障后下游设备仍能被公网访问，必须先确认 Route64 支持该前缀同时/重新路由到备用隧道，并按 Route64 的要求配置两条隧道的前缀和回程路由。否则可能出现 VPS 主动访问 IPv6 已切换成功，但外部访问下游前缀仍不可用的情况。

两条隧道即使连接同一台 VPS，也不能消除 VPS 宕机、VPS IPv4 出口故障或同一上游网络故障造成的共同故障。

### 检测时间说明

默认每 10 秒检测一次，连续失败 3 轮后切换；主隧道连续成功 5 轮后切回。实际切换时间还受每轮 ping 超时、系统调度和 Route64 恢复速度影响，不保证固定在 30 秒。探测目标必须允许 ICMPv6；如目标屏蔽 ping，请更换为可从两条隧道稳定探测的 IPv6 地址。

## 安装脚本行为与注意事项

安装脚本需要以 root 权限运行。如果检测到以下配置文件已经存在，脚本会拒绝覆盖：

- `/etc/wireguard/wg0.conf`
- `/etc/wireguard/wg1.conf`（仅在启用下游 wg1 时检查）

脚本会将已有 WireGuard 文件备份到 `/root/route64-wg-backups/`。如果配置中没有 Route64 客户端私钥，安装脚本会生成新密钥，并打印对应的**公钥**供你登记到 Route64 管理面板；私钥不会打印。新公钥尚未登记前，隧道无法正常握手。

脚本会启用 IPv6 转发，但不会清空或重写现有防火墙规则、修改 IPv4 路由、配置 NAT66 或修改其他无关的 WireGuard 接口。防火墙规则不会由脚本自动配置，请自行确认放行所需 UDP 端口并允许必要的 IPv6 转发流量。

## IP 地址与密钥安全

- 不沿用历史测试环境中的 VPS、隧道或客户端 IP；所有 Route64 地址和前缀都以当前 Route64 面板为准。
- `ROUTE64_ADDRESS`、`ROUTE64_PUBLIC_KEY`、`ROUTE64_ENDPOINT` 从当前隧道配置取得；`ROUTED_PREFIX` 从当前隧道页面确认。
- 下游 `wg1` 的 ULA 地址可同时留空，由安装脚本生成随机 ULA 前缀；手动填写时必须成对填写服务器和客户端地址。
- 不要公开 PrivateKey、PresharedKey、Token 或未脱敏的完整配置文件。
- 诊断报告可能包含公网 IP、主机名、路由和网络结构，分享前请先检查并脱敏。

## 免责声明

本工具用于辅助部署和故障诊断，不保证适用于所有 VPS 网络环境或 Route64 配置。请先备份重要配置，并在了解脚本行为后再执行。
