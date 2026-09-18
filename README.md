# isongwrt

A small LuCI app for managing a sing-box core on OpenWrt / iStoreOS.

It installs and switches the core binary, manages config files, controls the
service and shows logs. Settings follow the standard LuCI
**Save & Apply / Save / Reset** flow.

## Features

- **Core** — install, switch and roll back cores from the official
  [SagerNet/sing-box](https://github.com/SagerNet/sing-box) releases:
  channels `stable` / `rc` / `beta` / `alpha`, architecture matched, or a pinned tag.
  This project does not build kernels.
- **Config** — edit or upload config files; `sing-box check` runs before saving and
  the previous file is restored on failure; snapshots and restore included.
- **Service** — procd-managed start / stop / restart and autostart; a failed start
  shows the core log lines.
- **Logs** — core output from syslog, with optional auto refresh.
- **Dashboard** — optional sing-box `api` service that serves the official dashboard
  at `/dashboard/`; optional Clash API for Clash-style panels.

It uses its own binary path and service name (`isongwrt`), so a separately
installed `sing-box` package is left untouched.

## Platforms

| | |
|---|---|
| OpenWrt / iStoreOS | 24.10 (opkg/ipk), 25.12 (apk) |
| CI targets | x86_64 (add entries to the matrix for others) |
| Core manager | x86_64, aarch64, armv7, armv6, mips(el), riscv64, loongarch64 |

## Install

From the feed:

```sh
wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/install.sh | sh
```

Optional download-source selection (`mirror` is the default):

```sh
... | sh -s -- --source=direct     # GitHub first
... | sh -s -- --source=custom     # with ISONGWRT_FEED_BASE / ISONGWRT_GH_PROXY
```

Two-step, if you prefer:

```sh
wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/feed.sh | sh
opkg install luci-app-isongwrt     # 24.10
apk add luci-app-isongwrt          # 25.x
```

Packages are also attached to [Releases](../../releases) (`latest` = rolling build,
`v*` = tagged). Refresh LuCI afterwards; menu: **Services → isongwrt**.
The only dependency is `ca-bundle` — downloads use the built-in `uclient-fetch`.

## Build

```sh
echo "src-git isongwrt https://github.com/c000127/isongwrt.git" >> feeds.conf.default
./scripts/feeds update isongwrt && ./scripts/feeds install -a -p isongwrt
make menuconfig && make package/luci-app-isongwrt/compile V=s
```

CI builds on push to `main`, publishes a release and refreshes the `feed` branch.

## Pages

| Page | Purpose |
|---|---|
| Status | version, running/autostart, config check, port-conflict hint; start/stop/restart |
| Core | channel / pinned version / download prefix; check for updates; install, activate, remove, roll back |
| Config | edit or upload config shards; validate and save; snapshots |
| Logs | core log from syslog |
| Dashboard | dashboard / Clash API switch, port, access secret |

## Layout

```
/etc/isongwrt/
├── conf/                      # sing-box -C directory (files merged in name order)
│   ├── 10-user.json           # your config
│   └── 90-isongwrt-api.json   # written by the app: http_clients + api service
├── installed/                 # installed cores (for rollback)
├── backups/                   # config backups
└── active, previous           # current / previous core version
```

Only `90-isongwrt-api.json` is written by the app; an upgrade never overwrites
your own config.

## Backend CLI

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
	option enabled '0'               # service switch
	option core_path '/usr/lib/isongwrt/sing-box'
	option conf_dir '/etc/isongwrt/conf'
	option work_dir '/etc/isongwrt'
	option channel 'stable'           # stable | rc | beta | alpha
	option github_proxy ''            # optional download prefix
	option api_listen '0.0.0.0'
	option api_port '9090'
	option api_secret ''
	option pin_version ''             # empty = latest of the channel
	option dashboard '1'
	option dashboard_download_url ''  # empty = official
	option clash_api '0'
	option clash_port '9091'
	option clash_secret ''
```

## Server-side script

`server/singbox-deploy.sh` deploys a sing-box server on a VPS using the official
release binary (ss2022, no TLS). See [server/README.md](server/README.md).

## Notes

- Channel versions come from `releases.atom` (about 20 recent tags). For older
  channels, pin the tag explicitly.
- Default `api_port` is `9090`, which may collide with another dashboard
  (mihomo, nikki); change it if the core fails to start.
- The UI is currently Chinese only.
- For TUN setups, apply routing changes from local or out-of-band access.

## License

MIT
