# Route64 WireGuard 工具包

用于在 VPS 端部署和诊断 Route64 IPv6 隧道，并提供 IPv6 查询、下游 WireGuard 配置参考和双上游隧道故障切换工具。

**项目范围：仅支持 Ubuntu / Debian VPS。** 本项目不负责配置 OpenWrt、iStoreOS、Open-Box、局域网路由器通告（RA），也不会配置客户端设备。

## 功能

- 部署 Route64 主隧道 `wg0`。
- 可选部署下游 WireGuard 服务端 `wg1`。
- 下游 UDP 端口可自动选择未占用的高位端口（49152–65535）。
- 双 Route64 上游隧道健康检测和主备切换控制器（主隧道 `wg0`，备用隧道 `wg2`）。
- 只读网络诊断脚本。

> 双隧道控制器是独立模块。它不会自动向 Route64 申请第二条隧道，也不会自动生成第二条隧道的 Route64 配置；两条隧道必须先分别在 Route64 面板创建并配置到 VPS。

## 文件说明

- `install.sh`：中文全屏终端向导，导入 Route64 Linux 配置并部署 `wg0`，提供公网 IPv6 查询和网络状态查看。
- `configure.sh`：旧版独立配置转换工具，保留给手动配置流程使用。
- `diagnose.sh`：只读诊断 WireGuard、IPv6 路由与规则、IPv6 转发、防火墙和相关服务状态。
- `config/config.example`：单隧道安装配置模板。
- `failover/route64-failover.sh`：双上游健康检测和切换守护脚本。
- `failover/route64-failover.service`：systemd 服务单元。
- `failover/route64-failover.env.example`：主备接口和检测参数模板。
- `docs/TROUBLESHOOTING.md`：常见故障检查方法。

## 单隧道部署与 IPv6 查询

### 中文全屏终端向导

在 VPS 上以 root 身份执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ztesfyfi/route64-wireguard-toolkit/main/install.sh)
```

脚本进入独立终端页面（支持备用文本模式），主菜单包含：

1. **创建 / 安装 Route64 IPv6 隧道**：粘贴 Route64 导出的 Linux WireGuard 配置，单独输入 `END` 结束。
2. **查询 VPS 当前公网 IPv6**：查询公网出口 IPv6，并列出本机全局 IPv6 地址及 wg0 握手状态。
3. **查看 WireGuard 与 IPv6 状态**：查看接口、路由和 WireGuard 状态。

安装器会自动提取 `PrivateKey`、`Address`、`PublicKey`、可选 `PresharedKey`、`AllowedIPs`、`Endpoint`、`PersistentKeepalive` 和可选 `MTU`，生成 `/etc/wireguard/wg0.conf`，校验配置后启动 `wg-quick@wg0`。粘贴内容中附带的注释、`ip route add` 和 `ping` 命令会被忽略，不会写入 WireGuard 配置。

**不需要手动输入 Routed Prefix、隧道网关或接口名。** 对于常见的 `AllowedIPs = ::/1, 8000::/1`，`wg-quick` 会自动建立 IPv6 分流默认路由。不要再照抄配置注释中使用临时接口名的 `ip route add ::/0 via ...`，否则可能与 WireGuard 自动路由冲突。

安装结束会显示 wg0 隧道地址、路由、握手状态、IPv6 连通性测试，以及尝试经 wg0 查询到的公网 IPv6。若 Route64 配置没有 PrivateKey，脚本会生成新密钥并显示**公钥**；必须先将公钥登记到 Route64 面板才能握手。

### 单独查询 IPv6

也可以直接调用查询功能：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ztesfyfi/route64-wireguard-toolkit/main/install.sh) --query-ipv6
```

该查询显示当前公网出口 IPv6、本机全局 IPv6 地址和 wg0 握手信息。查询结果取决于 VPS 当前实际出口；没有可用 IPv6 路由时会明确显示查询失败，不会伪造地址。

### 安装安全边界

- 仅支持 Ubuntu / Debian VPS；安装功能需要 root 权限。
- 如果 `/etc/wireguard/wg0.conf` 已存在，脚本拒绝覆盖。
- 安装前备份 `/etc/wireguard/` 到 `/root/route64-wg-backups/`；启动失败时尝试回滚本次创建的配置。
- 私钥只写入 VPS 的 root 权限文件，不会上传到 GitHub 或查询服务。
- 脚本不会自动修改 IPv4 默认路由、防火墙规则、NAT66 或其他 WireGuard 接口。
- 安装成功不等于公网 IPv6 已经可用；以握手、探测和实际公网 IPv6 查询结果为准。

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
