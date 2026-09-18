# sing-box 服务端（落地机）部署

`server/singbox-deploy.sh` —— 在**落地服务器**（境外 VPS / 独服）上一键部署 sing-box 服务端，
与 isongwrt 面板托管的路由器 / 手机客户端配套使用。

> 服务端与客户端的分工：**服务端只负责「收流量 → 出网」**（默认 direct，并拦掉 BT/广告/私有地址/国内 IP）；
> 分流规则、fake-ip、面板与日志等都在客户端一侧（isongwrt 面板管理）。

---

## 1. 设计要点

| 项目 | 选择 | 说明 |
|---|---|---|
| 内核来源 | **官方 Release 原样二进制** | 不改名、不二次打包、不自编译；安装为 `/usr/local/bin/sing-box` |
| 产物选择 | Debian/Ubuntu 优先 `-glibc`，其余用静态产物 | 自动探测；glibc 产物打不开时自动回退静态产物 |
| 协议 | `shadowsocks-2022` / `2022-blake3-aes-256-gcm` | 32 字节 base64 密钥（脚本自动生成，0600 保存、不回显） |
| 多路复用 | `multiplex: {enabled, padding}` 服务端开启 | 与客户端 `h2mux + padding` 对齐 |
| TLS | **不使用** | 按既定裁决：ss2022 自身加密即可，减少握手与特征 |
| 路由 | 默认 `direct`，拦 `bittorrent` / 广告域名 / 私有地址 / `geoip-cn` | 防止落地机被当作回国中转，减少滥用面 |
| DNS | 默认 `8.8.8.8` + `1.1.1.1`；可选 smartdns | `--with-smartdns` 时监听 `127.0.0.1:6053`，**避开 53 端口冲突**；见 §5.1 |
| 幂等 | 密钥已存在即复用（不轮换） | 重复运行安全；改配置也不会换密钥 |
| 可回滚 | `rollback` 子命令 + `${BIN}.prev` + 配置备份 | 升级/改动前自动备份 |
| 可审计 | `/var/lib/isongwrt/deploy-record.json` | 版本、产物名、二进制/配置 sha256、端口、时间 |

---

## 2. 前置条件

- Debian / Ubuntu（其他 systemd 发行版可用 `--no-service` 自行托管）
- `x86_64` 或 `aarch64`
- root 权限；磁盘可用 ≥ 2G
- 一个**未被占用**的监听端口（默认 `15835`）

---

## 3. 快速开始

```bash
# 交互式选源（推荐）：会提示「直连 GitHub / 加速前缀」
bash singbox-deploy.sh install

# 非交互（国内服务器建议用加速前缀）
bash singbox-deploy.sh install --source mirror --gh-proxy https://ghfast.top/

# 锁定版本 + 顺带部署 smartdns + 放行防火墙
bash singbox-deploy.sh install --version v1.15.0-alpha.6 --with-smartdns --open-firewall
```

常用子命令：

```bash
bash singbox-deploy.sh status      # 版本/服务/监听/smartdns/部署记录
bash singbox-deploy.sh check       # 仅做 sing-box check
bash singbox-deploy.sh upgrade     # 升级到官方最新（自动备份 + 留 .prev）
bash singbox-deploy.sh rollback    # 回滚二进制与配置
bash singbox-deploy.sh uninstall   # 停服并移除二进制（配置与密钥保留）
bash singbox-deploy.sh install --dry-run    # 只打印将要做的操作（不改系统）
```

### 参数一览

| 参数 | 默认 | 说明 |
|---|---|---|
| `--listen-port N` | `15835` | ss2022 监听端口（TCP+UDP） |
| `--version vX.Y.Z[-pre.N]` | 官方最新 tag | 锁定版本；默认取官方 releases.atom 最新 |
| `--source auto\|direct\|mirror` | `auto` | 下载源：直连 / 加速前缀 / 自动回退 |
| `--gh-proxy URL` | `https://ghfast.top/` | 加速前缀（`--source mirror` 时使用） |
| `--binary /path/to/sing-box` | — | 使用你自备的二进制（跳过官方下载） |
| `--with-smartdns` | 关 | 部署本机 smartdns 作为服务端 DNS |
| `--smartdns-port N` | `6053` | smartdns 监听端口（避开 53） |
| `--with-ntp` | 关 | 启用 sing-box **内建 NTP 客户端**（校时；见 §5.2） |
| `--ntp-server` | `pool.ntp.org` | NTP 服务器（`--with-ntp` 时生效） |
| `--ntp-port` | `123` | NTP 端口 |
| `--ntp-interval` | `30m` | 校时间隔 |
| `--ntp-write-system` | 关 | 同时把校正后的时间**写回系统时钟**（隐含 `--with-ntp`；会给 unit 加 `CAP_SYS_TIME`） |
| `--open-firewall` | 关 | 检测到启用中的 ufw 时放行端口（会明确提示） |
| `--no-service` | 关 | 不装 systemd 单元，只生成配置与二进制 |
| `--dry-run` | 关 | 只打印计划；不写配置/密钥/单元，不改服务 |

也支持环境变量：`ISONGWRT_SOURCE`、`ISONGWRT_GH_PROXY`、`ISONGWRT_SS2022_PORT`、
`ISONGWRT_SMARTDNS_PORT`、`ISONGWRT_SMARTDNS_UPSTREAMS`，以及路径覆盖
`ISONGWRT_BIN` / `ISONGWRT_CONF_DIR` / `ISONGWRT_DATA_DIR` / `ISONGWRT_BACKUP_DIR` / `ISONGWRT_UNIT_FILE`。

---

## 4. 部署后验证

```bash
# 1) 版本与来源（应为官方版本号）
/usr/local/bin/sing-box version

# 2) 服务状态与端口
systemctl status sing-box --no-pager
ss -tlnp | grep 15835

# 3) 配置校验
/usr/local/bin/sing-box check -D /etc/sing-box -C /etc/sing-box/conf

# 4) 日志（只看 FATAL；后台 rule-set 更新失败会打 ERROR，属噪音）
journalctl -u sing-box -n 50 --no-pager | grep -E 'FATAL|ERROR'
```

**端到端验证（推荐）**：在客户端（路由器/手机）导入配置后访问 `https://www.google.com/generate_204`
应返回 `204`；服务端日志应出现 `inbound/shadowsocks[ss-in]: inbound multiplex connection to …`。

---

## 5. 生成的配置说明

配置按**分片**放在 `/etc/sing-box/conf/`（`sing-box run -D /etc/sing-box -C /etc/sing-box/conf`）：

| 文件 | 内容 | 备注 |
|---|---|---|
| `00_log.json` | `log.level = info` | 默认级别会输出 DEBUG，比较吵 |
| `01_inbounds.json` | ss2022 入站（`listen: ::`、`listen_port`、`password`、`multiplex`） | 密钥来自 `/var/lib/isongwrt/ss2022.password`（0600） |
| `02_outbounds.json` | `direct` / `block` | 落地机不需要复杂出站 |
| `03_route.json` | `sniff` → 拦 BT → 拦广告域名 → 拦私有地址 → `resolve` → 拦 `geoip-cn`；`final=direct` | 含 `http_clients` + `default_http_client`（1.14+ 下载规则集必需） |
| `04_dns.json` | 默认 `8.8.8.8`/`1.1.1.1`；`--with-smartdns` 时为 `127.0.0.1:6053` | 与 `route.default_domain_resolver` 对应 |
| `05_ntp.json` | 仅 `--with-ntp` 时生成：`{"ntp":{"enabled":true,"server":"pool.ntp.org","server_port":123,"interval":"30m"}}` | 见 §5.2；`--ntp-write-system` 会追加 `"write_to_system": true` |

### 5.1 `--with-smartdns` 会改哪些文件（与 apt 原样配置的关系）

`apt install smartdns` 下来的 `/etc/smartdns/smartdns.conf` 是**发行版 conffile**（400+ 行里只有 2~3 行生效：
`bind [::]:53`、`log-level info`，Debian 另加 `force-qtype-SOA 65`；**没有任何 `server` 上游**）。
本脚本**不改动它**，而是：

| 文件 | 变化 | 说明 |
|---|---|---|
| `/etc/smartdns/isongwrt.conf` | **新建**（我们的配置） | `bind 127.0.0.1:6053`（只回环 + 非 53）、`bind-tcp` 同端口、`speed-check-mode ping,tcp:80,tcp:443`、`cache-size 4096`、`prefetch-domain yes`、`serve-expired yes`、上游 `1.1.1.1/8.8.8.8/9.9.9.9`（`--smartdns-upstreams` 可改） |
| `/etc/default/smartdns` | **修改一行** | 设为 `SMART_DNS_OPTS="-c /etc/smartdns/isongwrt.conf"`；原文件首次备份为 `.isongwrt-orig` |
| `/etc/smartdns/smartdns.conf` | **不动** | 发行版文件保持原样（升级不产生 conffile 冲突，文档注释也保留） |

> 为什么用 `/etc/default/smartdns` 而不是 systemd drop-in？单元里是
> `ExecStart=/usr/sbin/smartdns -p /run/smartdns.pid $SMART_DNS_OPTS` + `EnvironmentFile=/etc/default/smartdns`，
> 而 **EnvironmentFile 的优先级高于 drop-in 的 `Environment=`**（实测：drop-in 会被空值覆盖，进程实参里没有 `-c`）。
> 另外注意：`Environment=` 的值含空格时必须整体加引号，否则 systemd 会把 `-c` 与路径当成两个赋值。

**顺带的安全收益**：发行版默认的 `bind [::]:53` 不再生效 → 既不会与 `systemd-resolved`/`dnsmasq` 抢 53，
也不会把 smartdns 暴露成公网开放解析器（开放解析器会被用于 DNS 放大攻击）。

权限：目录 `750`、配置文件 `640`（属主 `root:sing-box`）、密钥与部署记录 `600`。

---

### 5.2 `--with-ntp`：内建 NTP 校时

**为什么需要**：VPS 休眠/迁移后时钟漂移会直接破坏 ss2022 的**重放窗口**与 TLS 握手（表现为客户端能连上却无法认证/握手失败）。
sing-box 自 1.12+ 起内建 NTP 客户端（顶层 `ntp` 段），不必额外装 chrony/timesyncd。

```json
// /etc/sing-box/conf/05_ntp.json
{ "ntp": { "enabled": true, "server": "pool.ntp.org", "server_port": 123, "interval": "30m" } }
```

- **实测**：加入该段后启动日志出现 `INFO ntp: updated time: 2026-09-18 21:09:33 +0800`（沙箱真机验证）
- **注意**：`ntp` 是**顶层配置段**，不是 `services` 条目 —— 写成 `services:[{type:"ntp"}]` 会报
  `unknown inbound type: ntp`（实测）
- 默认**只校正 sing-box 自身使用的时间**（这正是 ss2022/TLS 需要的）。若还要把时间写回**系统时钟**，
  用 `--ntp-write-system`：配置里加 `"write_to_system": true`，并给 unit 追加
  `AmbientCapabilities=CAP_SYS_TIME` + `CapabilityBoundingSet=CAP_SYS_TIME`（服务以 `sing-box` 非特权用户运行，
  没有这个能力写系统时钟会失败）
- 默认服务器 `pool.ntp.org`（anycast、全球可达）；可 `--ntp-server` 换成你信任的源

## 6. 与客户端对接

服务端需要的信息只有三项：**地址、端口、ss2022 密钥**。

- 地址/端口：你部署时使用的公网 IP 与 `--listen-port`
- 密钥：`cat /var/lib/isongwrt/ss2022.password`（**不要**贴到聊天/仓库/工单里）

把这三项填进 `/root/singbox-router.json`（软路由）或 `/root/singbox-android.json`（手机）里
对应节点的 `server` / `server_port` / `password` 即可；两份配置的 `multiplex` 已按 `h2mux + padding` 对齐服务端。

> 若你使用 isongwrt 面板：把客户端配置在「配置管理」里保存即可，面板只补缺、不覆盖你的配置；
> API/官方 dashboard 由面板自动追加分片，**客户端配置里不要写 `api` / `clash_api`**。

---

## 7. 安全与凭据

- 脚本**不回显密钥**，密钥只落在服务器本地文件（0600）
- 仓库内**不含任何密钥**；配置生成是幂等的，重复部署不会轮换密钥
- 建议：只放行服务端口，其余端口最小化；定期 `upgrade` 跟进官方版本
- 若曾把密钥粘贴到外部，请轮换：删除 `/var/lib/isongwrt/ss2022.password` 后重新 `install`（会生成新密钥，
  同时需更新客户端）

---

## 8. 常见问题

**Q：国内服务器下载官方产物失败？**
`--source mirror --gh-proxy <你的加速前缀>`；或先在能访问的网络下载 tarball，再用 `--binary` 指定。

**Q：端口被占用 / 起不来？**
`ss -tlnp | grep <port>` 看占用者；换 `--listen-port`。脚本在 `install/upgrade` 前会检查端口与磁盘。

**Q：`journalctl` 里有 ERROR（rule-set 下载失败）但服务正常？**
1.14+ 规则集是**后台异步更新**，失败只打 ERROR，不影响启动与转发；本脚本的健康检查也只把 `FATAL` 视为失败。

**Q：为什么服务端不用 fake-ip / 分流规则集？**
分流在客户端做（面板托管），服务端越简单越稳；服务端只需拦掉不该走的流量（BT/广告/私有/国内）。

**Q：想用官方 `.deb` 包？**
可以，但 `.deb` 自带单文件配置与 systemd 单元，与本脚本的**分片配置**方式不同；
若要用 `.deb`，请自行维护 `/etc/sing-box/config.json`，本脚本不再负责该路径。

**Q：`--dry-run` 会改系统吗？**
不会：不写配置、不写密钥、不写 systemd 单元、不启停服务，只打印计划（版本解析与下载仍会进行以便验证 URL）。
