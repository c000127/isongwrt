# isongwrt — server-side deployment

`server/singbox-deploy.sh` installs a sing-box server on a VPS: it fetches the
official release binary, writes a small hardened config set and manages the
systemd unit.

The server only receives traffic and sends it out. Routing rules, fake-ip and the
dashboard belong to the client side (the isongwrt LuCI app).

## Design

| Item | Choice | Note |
|---|---|---|
| Core | official release binary, installed as `/usr/local/bin/sing-box` | never renamed, never rebuilt; `-glibc` assets on Debian/Ubuntu, static otherwise |
| Protocol | `shadowsocks-2022`, `2022-blake3-aes-256-gcm` | 32-byte base64 key, generated once and reused; no TLS |
| Multiplex | `{enabled, padding}` on the inbound | matches the clients' `h2mux + padding` |
| Routing | `final: direct`, rejects BitTorrent, ad domains, private addresses and `geoip-cn` | keeps the server from being used as a relay into CN or into the host network |
| DNS | `8.8.8.8` + `1.1.1.1`, or smartdns on `127.0.0.1:6053` | `--with-smartdns` |
| Time | built-in NTP client, `pool.ntp.org`, 30m interval | on by default; `--no-ntp` to disable |
| Logs | `level: info` into journald | no log files to rotate |
| Idempotent | existing ss2022 key is reused, never rotated | re-running is safe |
| Rollback | config and binary are backed up; `${BIN}.prev` + `rollback` | |
| Record | `/var/lib/isongwrt/deploy-record.json` | version, asset, binary/config sha256, port, time |

## Requirements

- Debian / Ubuntu (any systemd host with `--no-service`), `x86_64` or `aarch64`
- root, ≥ 2 GB free disk
- one free port (default `15835`)

## Quick start

```sh
bash singbox-deploy.sh install
bash singbox-deploy.sh install --source mirror --gh-proxy https://ghfast.top/
bash singbox-deploy.sh install --version v1.15.0-alpha.6 --with-smartdns
```

```sh
bash singbox-deploy.sh status        # version, service, listeners, record
bash singbox-deploy.sh check         # config check only
bash singbox-deploy.sh upgrade       # backup + install latest + keep .prev
bash singbox-deploy.sh rollback      # restore binary and config
bash singbox-deploy.sh uninstall     # stop and remove the binary (config kept)
bash singbox-deploy.sh install --dry-run   # print the plan, change nothing
```

## Parameters

| Flag | Default | Description |
|---|---|---|
| `--listen-port N` | `15835` | ss2022 port (TCP + UDP) |
| `--version vX.Y.Z[-pre.N]` | latest tag | pin the release |
| `--source auto\|direct\|mirror` | `auto` | download source |
| `--gh-proxy URL` | `https://ghfast.top/` | prefix for `mirror` |
| `--binary PATH` | — | use your own binary instead of downloading |
| `--with-smartdns` | off | deploy smartdns (see §Config files) |
| `--smartdns-port N` | `6053` | smartdns port |
| `--with-ntp` | **on** | built-in NTP client |
| `--no-ntp` | — | disable the NTP client |
| `--ntp-server` / `--ntp-port` / `--ntp-interval` | `pool.ntp.org` / `123` / `30m` | NTP settings |
| `--ntp-write-system` | off | also set the system clock (adds `CAP_SYS_TIME`) |
| `--open-firewall` | off | allow the port in ufw when it is active |
| `--no-service` | off | skip systemd; start it yourself |
| `--dry-run` | off | print the plan, write nothing |

Environment variables: `ISONGWRT_SOURCE`, `ISONGWRT_GH_PROXY`, `ISONGWRT_SS2022_PORT`,
`ISONGWRT_SMARTDNS_PORT`, `ISONGWRT_SMARTDNS_UPSTREAMS`, `ISONGWRT_NTP_*`, and path
overrides `ISONGWRT_BIN`, `ISONGWRT_CONF_DIR`, `ISONGWRT_DATA_DIR`,
`ISONGWRT_BACKUP_DIR`, `ISONGWRT_UNIT_FILE`, `ISONGWRT_SMARTDNS_CONF`,
`ISONGWRT_SMARTDNS_ENVFILE`.

## Verify

```sh
/usr/local/bin/sing-box version
systemctl status sing-box --no-pager
ss -tlnp | grep 15835
/usr/local/bin/sing-box check -D /etc/sing-box -C /etc/sing-box/conf
journalctl -u sing-box -n 50 --no-pager | grep -E 'FATAL|ERROR'
```

`ERROR` lines about rule-set downloads are background retries and are harmless;
only `FATAL` fails the script's health check. Traffic works end to end when the
log shows `inbound/shadowsocks[ss-in]: inbound multiplex connection to …`.

## Config files

`/etc/sing-box/conf/` is loaded with `sing-box run -D /etc/sing-box -C /etc/sing-box/conf`.

| File | Content |
|---|---|
| `00_log.json` | `log.level = info` |
| `01_inbounds.json` | ss2022 inbound: `listen: "::"`, port, key, `multiplex` |
| `02_outbounds.json` | `direct` |
| `03_route.json` | `sniff`, rejects (BT / ads / private / geoip-cn), `final: direct`, `http_clients` |
| `04_dns.json` | `8.8.8.8` + `1.1.1.1`, or smartdns on `127.0.0.1:6053` |
| `05_ntp.json` | built-in NTP client (skipped with `--no-ntp`) |

Permissions: directory `750`, config `640` (`root:sing-box`), key and record `600`.

### smartdns (`--with-smartdns`)

The distribution file `/etc/smartdns/smartdns.conf` is a dpkg conffile and is
**left untouched** (it ships no upstream servers and binds `[::]:53`). Instead:

| File | Change |
|---|---|
| `/etc/smartdns/isongwrt.conf` | created: `bind 127.0.0.1:6053`, `bind-tcp` same port, speed check, cache, prefetch, serve-expired, upstreams |
| `/etc/default/smartdns` | one line: `SMART_DNS_OPTS="-c /etc/smartdns/isongwrt.conf"` (original kept as `.isongwrt-orig`) |

A systemd drop-in cannot be used here: the unit's `EnvironmentFile` takes
precedence over `Environment=`, and an unquoted value would be split at spaces.
Loopback-only binding keeps smartdns off port 53 and off the public network.

## Connect clients

The server side needs the address, the port and the ss2022 key
(`/var/lib/isongwrt/ss2022.password` — do not publish it).

Fill `server` / `server_port` / `password` in the client config
(`singbox-router.json` for a router, `singbox-android.json` for Android); the
`multiplex` settings already match. When using the LuCI app, import the client
config under **Config** — the app only adds its own API shard and never overwrites
your files. Do not put `api` or `clash_api` in the client config.

## Security

- The script never prints the key; it is stored on the server only (`0600`).
- No secrets are kept in the repository; re-running does not rotate the key.
- Rotating the key: remove `/var/lib/isongwrt/ss2022.password`, run `install`
  again, then update the clients.

## FAQ

**Download fails on a server in CN** — use `--source mirror --gh-proxy <prefix>`,
or download the tarball elsewhere and pass `--binary`.

**Port already in use** — `ss -tlnp | grep <port>`; pick another `--listen-port`.

**Why is there no fake-ip or rule-set routing on the server?** Routing is done by
the clients; the server stays simple and only rejects traffic it should not carry.

**Why not use the official `.deb`?** It ships a single-file config and its own unit,
which does not fit the shard layout used here. Pick one; this script does not manage
that path.

**Does `--dry-run` change anything?** No: no config, key, unit or service change.
Version resolution and the download still run so the URLs can be checked.
