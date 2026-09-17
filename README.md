# isongwrt

OpenWrt / iStoreOS 上的 **sing-box 轻量管理面板**（LuCI 应用）。

| 功能 | 说明 |
|---|---|
| 内核分级管理 | 从官方 `SagerNet/sing-box` 安装/切换内核：`stable` / `rc` / `beta` / `alpha`，自动匹配架构（优先 musl），支持指定版本、多版本共存、回滚 |
| 配置管理 | 上传或在线编辑配置，保存前自动 `sing-box check`，失败自动回退；自动备份/恢复 |
| 启停控制 | procd 托管（崩溃拉起、开机自启），启动失败直接回显内核日志原因 |
| 日志 | 面板查看内核 syslog，支持自动刷新 |
| Web 面板 | 一键启用 sing-box 内置 `api` 服务：官方 dashboard 自动下载并托管在 `/dashboard/`；可选 Clash API 接 zashboard/metacubexd |

与官方 `sing-box` 包**互不干扰**：独立内核路径（`/usr/lib/isongwrt/sing-box`）与服务名（`isongwrt`）。

## 兼容性

`openwrt-24.10`（opkg/ipk）· `openwrt-25.12`（apk）· CI 默认构建 **x86_64**（其它架构在矩阵里加一行即可）。
内核管理器本身支持 x86_64 / aarch64 / armv7 / armv6 / mips(el) / riscv64 / loongarch64。

## 安装

### A. Install From Feed（推荐）

```sh
# 一键：自动识别版本与架构、添加 feed（含签名公钥）并安装；feed 不可达时回退 Releases
wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/install.sh | sh
```

> `raw.githubusercontent.com` 在部分网络（含国内）不可达，因此脚本与 feed 默认走 **jsDelivr CDN**，
> 并自动回退 `fastly.jsdelivr.net` → `raw.githubusercontent.com`；可用 `ISONGWRT_FEED_BASE` 指定自建镜像。

分两步自己控制：

```sh
wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/feed.sh | sh   # 加源
opkg install luci-app-isongwrt        # 24.10
apk add luci-app-isongwrt             # 25.x
```

feed 由 CI 发布在 `feed` 分支，经 jsDelivr 分发：
`https://cdn.jsdelivr.net/gh/c000127/isongwrt@feed/<branch>/<arch>/isongwrt`。

**关于签名**：feed 索引已用密钥签名（ipk 用 usign，apk 用 PEM），公钥随 feed 发布、`feed.sh` 自动导入。
签名用于防「镜像/链路被替换成恶意包」；未导入公钥时 apk 需 `--allow-untrusted`（脚本会自动处理）。

### B. 从 Releases 下载

从 [Releases](../../releases) 取包（`latest` 是滚动预发布，`v*` 是正式版）：

```sh
opkg install luci-app-isongwrt_*_all.ipk        # 24.10
apk add luci-app-isongwrt-*.apk                 # 25.x
```

装完刷新 LuCI（`/etc/init.d/uhttpd restart`），菜单：**服务 → isongwrt**。仅依赖 `ca-bundle`（下载走系统自带 `uclient-fetch`，无需 curl）。

### C. 自行编译

```sh
echo "src-git isongwrt https://github.com/c000127/isongwrt.git" >> feeds.conf.default
./scripts/feeds update isongwrt && ./scripts/feeds install -a -p isongwrt
make menuconfig && make package/luci-app-isongwrt/compile V=s
```

CI 在 `main` 推送时构建 → 上传 Artifacts → 发布 Release（`v*` tag 为正式版，否则更新 `latest`）→ 发布 `feed` 分支。

## 使用

| 页面 | 用途 |
|---|---|
| 运行状态 | 版本、运行/自启状态、配置校验、端口占用提示；启停/重启 |
| 内核管理 | 选渠道或填指定版本安装（后台任务 + 实时进度 + 断点续传）；激活/删除/回滚 |
| 配置管理 | 分片文件在线编辑或上传；校验并保存（失败回退）；快照与恢复 |
| 日志 | syslog 中的内核日志 |
| 面板 | 官方 dashboard / Clash API 开关、监听地址与密钥、面板下载源 |

首次使用：装内核 → 上传配置 → 勾选开机自启并启动 → 面板页保存并打开 `/dashboard/`。

## 配置模型

```
/etc/isongwrt/
├── conf/                      # sing-box -C 分片目录（按文件名排序合并）
│   ├── 10-user.json           # 你的配置（面板上传/编辑）
│   └── 90-isongwrt-api.json   # 面板维护：http_clients + api 服务 / dashboard
├── installed/                 # 历史内核（回滚用）
├── backups/                   # 配置备份
├── active / previous          # 当前与上一版本
```

面板只写 `90-isongwrt-api.json`，升级不会覆盖你的配置。

## 面板实现要点

- sing-box **1.14+** 内置 `api` 服务：开启 dashboard 后内核自动下载官方面板（`gh-pages` zip）并在 `/dashboard/` 托管，默认每天检查更新——因此本项目不打包任何前端。
- **必须显式声明 HTTP client**：1.14 起「隐式默认客户端」已弃用且会 FATAL；面板分片自带 `http_clients`（tag `isongwrt-dashboard`），只给 dashboard 使用，不覆盖你的 `route.default_http_client`。
- **端口冲突**：`api_port` 默认 `9090` 与 mihomo/nikki 的 Clash API 相同，同机部署请改（如 `9095`），否则启动失败（状态页会提示）。
- **下载慢/失败**：可换面板资源下载源，或手工把面板文件放进 `<work_dir>/dashboard/`（非空且无 `.etag` 时按原样提供、不自动更新）。
- 用 Clash 协议面板（zashboard/metacubexd）：开启 Clash API，面板指向 `<路由器>:<clash_port>`。

## 命令行后端

```sh
ctl status | channels | releases alpha 10
ctl install alpha | install rc v1.15.0-rc.1 | install-bg alpha | install-status
ctl installed | activate <ver> | rollback | remove <ver>
ctl config-list | config-get 10-user | config-save 10-user < f.json
ctl config-backup | config-restore <file>
ctl api-sync | check | log 200 | service start|stop|restart|enable|disable
```

## UCI

```uci
config isongwrt 'main'
	option enabled '0'              # 服务开关
	option core_path '/usr/lib/isongwrt/sing-box'
	option conf_dir '/etc/isongwrt/conf'
	option work_dir '/etc/isongwrt'
	option channel 'stable'         # stable | rc | beta | alpha
	option github_proxy ''          # GitHub 加速前缀（可选）
	option api_listen '127.0.0.1'   # 0.0.0.0 = 局域网可访问面板
	option api_port '9090'
	option api_secret ''
	option dashboard '1'
	option dashboard_download_url '' # 面板资源下载源（留空=官方）
	option clash_api '0'
	option clash_port '9091'
	option clash_secret ''
```

## 结构

```
luci-app-isongwrt/
├── Makefile                                       # OpenWrt 包（luci.mk）
├── htdocs/luci-static/resources/
│   ├── tools/isongwrt.js                          # 前端公共模块
│   └── view/isongwrt/{overview,core,config,log,dashboard}.js
└── root/
    ├── etc/config/isongwrt                        # UCI 默认值
    ├── etc/init.d/isongwrt                        # procd 服务
    ├── etc/uci-defaults/99-isongwrt               # 首次初始化
    ├── usr/lib/isongwrt/ctl                       # 后端（busybox sh）
    └── usr/share/{luci/menu.d,rpcd/acl.d}/luci-app-isongwrt.json
feed.sh / install.sh                               # feed 安装脚本
```

## 已知限制

- 渠道解析用 `releases.atom`（约 20KB，路由器友好），只覆盖最近约 20 个版本；`beta` 等较老渠道为空时用「指定版本」直接填 tag。
- 未签名场景下 apk 需 `--allow-untrusted`（本仓库默认已配置签名密钥，正常无需关心）。
- TUN 首次启用建议在带外/本地控制台下进行（会改写路由）。
- 未做 i18n（界面中文）。

## License

MIT
