# isongwrt

OpenWrt / iStoreOS 上的 **sing-box 轻量管理面板**（LuCI 应用）。

只做五件事，保持简单可靠：

| # | 功能 | 说明 |
|---|---|---|
| 1 | **内核分级管理** | 从官方 `SagerNet/sing-box` Releases 安装/切换内核，支持 `stable` / `rc` / `beta` / `alpha` 四级渠道，自动匹配本机架构（优先 musl 构建），保留历史版本可回滚 |
| 2 | **配置管理** | Web 上传 / 在线编辑 / 校验 / 备份恢复；配置以「分片目录」方式加载（`sing-box run -C <conf_dir>`），面板自动维护 API 分片，不覆盖你的配置 |
| 3 | **控制启停** | 启动 / 停止 / 重启 / 开机自启（procd 托管，崩溃自动拉起） |
| 4 | **日志查看** | 面板内置日志页，读取 syslog 中内核输出，支持自动刷新 |
| 5 | **Web 管理面板** | 一键启用 sing-box 1.14+ 内置 `api` 服务：官方 **sing-box-dashboard** 由内核自动下载并托管在 `/dashboard/`；可选启用 Clash API 以便使用 zashboard / metacubexd |

> 与官方 `sing-box` 软件包**互不干扰**：isongwrt 使用自己的内核路径（`/usr/lib/isongwrt/sing-box`）与服务名（`isongwrt`），可以与你已有的 sing-box 包共存或替代。

## 兼容性

- **OpenWrt 24.10（opkg / .ipk）** 与 **OpenWrt 25.x（apk / .apk）**：同一套源码，由 SDK 按分支自动产出对应格式。
- iStoreOS 25.x（apk-tools 3）实测可用。
- 架构：x86_64 / aarch64 / armv7 / armv6 / mips(el) / riscv64 / loongarch64（内核资产按表映射）。

## 安装

### 方式一：Releases 安装包（推荐）

从本仓库 [Releases](../../releases) 或 CI Artifacts 下载对应架构与分支的包：

```sh
# OpenWrt 24.10 (opkg)
opkg install luci-app-isongwrt_*.ipk

# OpenWrt 25.x (apk)
apk add --allow-untrusted luci-app-isongwrt-*.apk

# 依赖（若未装）
opkg install curl ca-bundle        # 或 apk add curl ca-bundle
```

安装后刷新 LuCI（`/etc/init.d/uhttpd restart` 或清理浏览器缓存），菜单出现在 **服务 → isongwrt**。

### 方式二：自建 feed 编译

```sh
# 在 OpenWrt SDK / buildroot 中
echo "src-git isongwrt https://github.com/c000127/isongwrt.git" >> feeds.conf.default
./scripts/feeds update isongwrt && ./scripts/feeds install -a -p isongwrt
make menuconfig   # LuCI → Applications → luci-app-isongwrt
make package/luci-app-isongwrt/compile V=s
```

### 方式三：GitHub Actions 自动构建

`.github/workflows/build.yml` 已配置矩阵构建（`openwrt-24.10` / `openwrt-25.12` / `SNAPSHOT` × 常用架构），
推送到 `main` 或手动 `workflow_dispatch` 触发，产物在 Actions Artifacts 中。

## 使用

| 页面 | 用途 |
|---|---|
| **运行状态** | 内核版本、运行/自启状态、配置校验结果；一键启动/停止/重启 |
| **内核管理** | 选择渠道安装/升级；指定精确版本（如 `v1.15.0-alpha.5`）；已安装版本列表可激活/删除；一键回滚 |
| **配置管理** | 选择分片文件在线编辑，或直接上传 `config.json`；保存前自动 `sing-box check`，失败自动回退；备份恢复 |
| **日志** | syslog 中的内核日志（logread），可自动刷新 |
| **面板** | 开关官方 dashboard / Clash API，配置监听地址、端口与密钥，一键跳转面板 |

### 第一次使用

1. 「内核管理」选渠道 → **开始安装**（网络受限时填 GitHub 加速前缀，如 `https://ghfast.top/`）
2. 「配置管理」上传你的 sing-box 配置（保存为 `10-user.json`），保存时会自动校验
3. 「运行状态」勾选**开机自启**并**启动**
4. 「面板」保存并应用 → 打开面板（默认 `http://<路由器>:9090/dashboard/`）

## 配置模型（分片目录）

```
/etc/isongwrt/
├── conf/                      # sing-box -C 分片目录
│   ├── 10-user.json           # 你的配置（面板上传/编辑）
│   └── 90-isongwrt-api.json   # 面板维护：api 服务 / dashboard / 可选 Clash API
├── installed/                 # 历史内核（可回滚）
├── backups/                   # 配置备份
├── active                     # 当前激活版本
└── previous                   # 上一版本（回滚用）
```

> 分片文件按文件名排序合并。面板只写 `90-isongwrt-api.json`，因此升级/换配置不会互相覆盖；
> 若你的配置里同时定义了 `services` 或 `experimental.clash_api`，请关闭面板的对应开关或合并进用户配置。

## 面板实现说明（关于 sing-box-dashboard）

- **官方 dashboard 仍在使用中**：代码仓库 [SagerNet/sing-box-dashboard](https://github.com/SagerNet/sing-box-dashboard)（活跃维护），
  **构建产物发布在其 `gh-pages` 分支**，这正是内核默认的下载源：
  `https://github.com/SagerNet/sing-box-dashboard/archive/refs/heads/gh-pages.zip`。
- sing-box **1.14.0** 起内置 `api` 服务（gRPC / gRPC-Web），开启 `dashboard` 后内核会：
  下载解压到工作目录的 `dashboard/` → 在 API 监听端口上以 `/dashboard/` 提供，其它浏览器请求自动跳转过去；
  默认每天检查更新（`update_interval`）。
- 因此 isongwrt **不需要打包任何前端**，面板随内核更新。
- 想用 Clash 协议面板（zashboard / metacubexd）：在「面板」页开启 **Clash API**，把面板地址指向 `<路由器>:<clash_port>`，密钥填 Clash 密钥即可。

## UCI 配置参考

```uci
config isongwrt 'main'
	option enabled '0'            # 服务开关
	option core_path '/usr/lib/isongwrt/sing-box'
	option conf_dir '/etc/isongwrt/conf'
	option work_dir '/etc/isongwrt'
	option channel 'stable'       # stable | rc | beta | alpha
	option github_proxy ''        # 可选加速前缀
	option api_listen '127.0.0.1' # 面板监听地址（0.0.0.0 = 局域网可访问）
	option api_port '9090'
	option api_secret ''
	option dashboard '1'          # 官方 dashboard
	option clash_api '0'          # 可选 Clash API
	option clash_port '9091'
	option clash_secret ''
```

## 命令行后端

面板所有功能都由 `/usr/lib/isongwrt/ctl` 提供，可单独使用（便于排障）：

```sh
ctl status                      # JSON 状态
ctl channels                    # 各渠道最新版本
ctl releases alpha 10           # 列出版本
ctl install alpha               # 安装 alpha 最新
ctl install rc v1.15.0-rc.1     # 指定版本
ctl installed | rollback | activate <ver> | remove <ver>
ctl config-list | config-get 10-user | config-save 10-user < file.json
ctl config-backup | config-restore <backup-file>
ctl api-sync | check | log 200
ctl service start|stop|restart|enable|disable
```

## 目录结构

```
luci-app-isongwrt/
├── Makefile                                  # OpenWrt 包（luci.mk）
├── htdocs/luci-static/resources/
│   ├── tools/isongwrt.js                     # 前端公共模块（调用 ctl + UCI）
│   └── view/isongwrt/{overview,core,config,log,dashboard}.js
└── root/
    ├── etc/config/isongwrt                   # UCI 默认值
    ├── etc/init.d/isongwrt                   # procd 服务
    ├── etc/uci-defaults/99-isongwrt          # 首次安装初始化
    ├── usr/lib/isongwrt/ctl                  # 后端（busybox sh）
    └── usr/share/{luci/menu.d,rpcd/acl.d}/luci-app-isongwrt.json
```

## 已知限制 / 待办

- 内核下载使用 GitHub Releases；受限网络请配置加速前缀（面板内可填）。
- 面板自身不带代理链，首次下载内核前若无网络出口，可先用其它方式放一份内核到 `core_path`。
- 未做 i18n（界面为中文），如需英文可后续补 po。
- 未内置 sing-box 配置模板市场（保持简单；配置由用户上传）。

## License

MIT
