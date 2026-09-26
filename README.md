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
- **Dashboard** — the sing-box native `services.api` service, serving the official
  dashboard at `/dashboard/`. The panel injects the API shard and auto-generates the
  access secret.

The panel's management plane is the **native sing-box `services.api`** only
(`api_listen` / `api_port` / `api_secret` + the official dashboard). **This project
does not use the Clash compatibility layer** (decision of 2026-09-20) — there is no
`clash_api` / `clash_port` / `clash_secret` option, and no Clash-style panel is
supported by this app.

It uses its own binary path and service name (`isongwrt`), so a separately
installed `sing-box` package is left untouched.

## Platforms

| | |
|---|---|
| OpenWrt / iStoreOS | 24.10 (opkg/ipk), 25.12 (apk) |
| CI targets | x86_64 only; other architectures install from Releases (the package itself is `Architecture: all`) |
| Core manager | x86_64, aarch64, armv7, armv6, mips(el), riscv64, loongarch64 |

## Install

From the feed (recommended):

```sh
wget -O - https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/install.sh | sh
```

`install.sh` tries the feed path first (`feed.sh`: adds the signed package feed,
then installs `luci-app-isongwrt`), and falls back to the GitHub Releases asset if
that path fails. The Releases fallback downloads `SHA256SUMS.txt` from the same
release and **refuses to install** if the package hash does not match.

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

> `cdn.jsdelivr.net` caches branch references (about 12 h). If you need the current
> `main` right now, use `--source=direct` (fetches `raw.githubusercontent.com` first).

Packages are also attached to
[Releases](https://github.com/c000127/isongwrt/releases) (`latest` = rolling build,
`v*` = tagged). Each release carries `SHA256SUMS.txt`; verify a downloaded asset with:

```sh
sha256sum -c SHA256SUMS.txt --ignore-missing
```

Refresh LuCI afterwards; menu: **Services → isongwrt**.
Dependencies: `luci-base` and `ca-bundle`. Downloads use `curl` when present, and
otherwise the built-in `uclient-fetch` / `wget`.

## Build

```sh
echo "src-git isongwrt https://github.com/c000127/isongwrt.git" >> feeds.conf.default
./scripts/feeds update isongwrt && ./scripts/feeds install -a -p isongwrt
make menuconfig && make package/luci-app-isongwrt/compile V=s
```

CI builds **only when the app directory or the workflow itself changes**
(`paths:` filter: `luci-app-isongwrt/**`, `.github/workflows/build.yml`). A
docs-only or `rules/`-only commit does not build and does not publish; pushing to
`main` publishes a rolling release and refreshes the `feed` branch, and pushing a
`v*` tag publishes a tagged release.

## Pages

| Page | Purpose |
|---|---|
| Status | version, running/autostart, config check, port-conflict hint; start/stop/restart |
| Core | channel / pinned version / download prefix; check for updates; install, activate, remove, roll back |
| Config | edit or upload config shards; validate and save; snapshots |
| Logs | core log from syslog |
| Dashboard | enable the dashboard, API listen address / port / access secret |

## Layout

```
/etc/isongwrt/
├── conf/                      # sing-box -C directory (files merged in name order)
│   ├── 10-user.json           # your config (template written on first install)
│   └── 90-isongwrt-api.json   # written by the app: http_clients + services.api
├── installed/                 # installed cores (for rollback)
├── backups/                   # config backups
├── cache/releases.atom        # cached release list (about 20 recent tags)
├── active, previous           # current / previous core version
└── api-source                 # who provides the API service: config | panel | none
```

Only `90-isongwrt-api.json` is written by the app; an upgrade never overwrites
your own config. `/etc/isongwrt/rules/` is **not** created by the app — put local
rule sets wherever your own config expects them.

## Backend CLI

```sh
ctl status | channels | releases alpha 10
ctl install alpha | install rc v1.15.0-rc.1 | install-bg alpha | install-status
ctl installed | activate <ver> | rollback | remove <ver>
ctl config-list | config-get 10-user | config-save 10-user < f.json
ctl config-backup | config-restore <file>
ctl api-sync | api-secret-new | check | log 200
ctl service start|stop|restart|enable|disable
```

## UCI

```uci
config isongwrt 'main'
	option enabled '0'                # service switch
	option core_path '/usr/lib/isongwrt/sing-box'
	option conf_dir '/etc/isongwrt/conf'
	option work_dir '/etc/isongwrt'
	option channel 'stable'           # stable | rc | beta | alpha
	option github_proxy ''            # optional download prefix
	option api_listen '0.0.0.0'       # native sing-box services.api
	option api_port '9090'
	option api_secret ''              # empty = auto-generated on install / sync
	option pin_version ''             # empty = latest of the channel
	option dashboard '1'
	option dashboard_download_url ''  # empty = official
```

- `api_secret` is **generated automatically** the first time the panel writes the API
  shard (first install or `ctl api-sync`) and written back to UCI; it can be
  regenerated from the Dashboard page (`ctl api-secret-new`).
- `pin_version` is **not read by `ctl`**: it is a panel-side parameter that the Core
  page passes to `ctl install <tag>`. The UCI option only records what the page last
  selected, so a manual `ctl install alpha` is not affected by it.
- `github_proxy` works the same way — the page passes it through to `ctl`.

## Server-side script

`server/singbox-deploy.sh` deploys a sing-box server on a VPS using the official
release binary (ss2022, no TLS). See [server/README.md](server/README.md).

## Rules

`rules/` holds the extra rule sets shipped with this repository (see
[rules/README.md](rules/README.md)); clients can fetch them straight from jsDelivr.
`cn-extra` is published by the maintainer's tooling; `echsdirect` / `echsdirectip` are converted
from the public echs-top lists and published by [.github/workflows/rules-echs.yml](.github/workflows/rules-echs.yml)
(daily + manual, guardrailed, with `rules/manifest-echs.json` as provenance).

**Restart-time prefetch (opt-in, default off)**: before the panel's start/restart, `ctl` *probes*
every `route.rule_set[].type=="remote"` URL — HEAD only (never the body), 4s per URL, **12s total
budget**, 8 in parallel. `restart` aborts when a rule set is confirmed unreachable (the running core
is left untouched, and a boot-time network outage cannot lock you out because boot does not go through
`ctl`); `start` only warns and continues. Escape hatches: `--skip-prefetch`,
`uci set isongwrt.main.prefetch=0` (**the default**), or `ISONGWRT_SKIP_PREFETCH=1`.

> The first version of this feature *downloaded* everything on that same synchronous path: 51s on a
> real router, which exceeded the panel's XHR timeout and left the service unable to start
> (`XHR request timed out`). Hence the current shape: probe, hard budget, and start/restart split.

## Notes

- Channel versions come from `releases.atom` (about 20 recent tags). For older
  channels, pin the tag explicitly.
- Default `api_port` is `9090`, which may collide with another dashboard
  (mihomo, nikki); change it if the core fails to start.
- The UI is currently Chinese only.
- For TUN setups, apply routing changes from local or out-of-band access.

## License

MIT
