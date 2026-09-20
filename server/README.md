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
| Integrity | every download is checked before it is installed or executed | upstream checksums file, else the GitHub release asset digest, else the sha256 table pinned in the script; `--checksum` overrides all three; a mismatch aborts |
| Protocol | `shadowsocks-2022`, `2022-blake3-aes-256-gcm` | 32-byte base64 key, generated once and reused; no TLS |
| Multiplex | `{enabled, padding}` on the inbound | matches the clients' `h2mux + padding` |
| Routing | `final: direct`, rejects BitTorrent, ad domains, private addresses and `geoip-cn` | keeps the server from being used as a relay into CN or into the host network |
| DNS | `8.8.8.8` + `1.1.1.1`, or smartdns on `127.0.0.1:6053` | `--with-smartdns` |
| Time | built-in NTP client, `pool.ntp.org`, 30m interval | on by default; `--no-ntp` disables it **and deletes `05_ntp.json`** |
| Logs | `level: info` into journald | no log files to rotate |
| Idempotent | existing ss2022 key is reused, never rotated | re-running is safe |
| Rollback | `${BIN}.prev` (plus one copy per version) and config backups under `/var/backups/isongwrt` | the legacy backup directory is searched too; a failed install/upgrade restores the previous state automatically |
| Record | `/var/lib/isongwrt/deploy-record.json` + `deploy-history.log` | action, version, previous version, tags, revision, asset, binary/config sha256, port, time |
| State | `/var/lib/sing-box` (`-D`) | runtime state such as `cache.db`; the only directory the service may write |

## Requirements

- Debian / Ubuntu (`apt` + `dpkg`), `amd64` or `aarch64`; other derivatives work as
  long as `apt-get`, `dpkg --print-architecture`, `df -BG` and systemd are present
  (`--no-service` skips systemd but the config layout still assumes these tools)
- root, ≥ 2 GB free disk
- one free port (default `15835`)
- `curl` is required up front (install it with `apt-get install -y curl`); `openssl`
  and `iproute2` are installed automatically when missing

## Quick start

```sh
bash singbox-deploy.sh install
bash singbox-deploy.sh install --version v1.15.0-alpha.6 --with-smartdns
# behind a slow/blocked route (third-party accelerator, announced loudly; the sha256
# is still verified before anything is installed):
bash singbox-deploy.sh install --source mirror --gh-proxy https://ghfast.top/
```

```sh
bash singbox-deploy.sh status        # version, service, listeners, record
bash singbox-deploy.sh check         # config check only
bash singbox-deploy.sh upgrade       # backup + install the newest release + keep .prev
bash singbox-deploy.sh rollback      # restore the newest binary and config backup
bash singbox-deploy.sh uninstall     # stop and remove the binary (config and key kept)
bash singbox-deploy.sh install --dry-run   # print the plan, change nothing
```

## Parameters

| Flag | Default | Description |
|---|---|---|
| `--role NAME` | `landing` | **recorded only**: role-specific config templates do not exist yet, the generated profile is always the landing one |
| `--listen-port N` | `15835` | ss2022 port (TCP + UDP) |
| `--version vX.Y.Z[-pre.N]` | newest tag | pin the release |
| `--source auto\|direct\|mirror` | `auto` | `auto` tries GitHub directly and only then the prefix; `mirror` uses the prefix from the start (both announce it) |
| `--gh-proxy URL` | `https://ghfast.top/` | prefix for `mirror`/the fallback; `https://` is enforced, `http://` is refused |
| `--checksum SHA256` | — | expected sha256 of the release asset (64 hex); use it when the asset is downloaded out of band |
| `--allow-unverified` | off | install even when no checksum can be obtained (unsafe; refuses to run silently) |
| `--binary PATH` | — | use your own binary instead of downloading |
| `--with-smartdns` | off | deploy smartdns (see §Config files) |
| `--smartdns-port N` | `6053` | smartdns port |
| `--smartdns-upstreams "LIST"` | `1.1.1.1 8.8.8.8 9.9.9.9` | smartdns upstream servers |
| `--with-ntp` | **on** | built-in NTP client |
| `--no-ntp` | — | disable the NTP client and remove `05_ntp.json` |
| `--ntp-server` / `--ntp-port` / `--ntp-interval` | `pool.ntp.org` / `123` / `30m` | NTP settings |
| `--ntp-write-system` | off | also set the system clock (adds `CAP_SYS_TIME`) |
| `--open-firewall` | off | allow the port in ufw when it is active |
| `--no-service` | off | skip systemd; start it yourself |
| `--dry-run` | off | print the plan, write nothing (the download still runs so the URL can be checked; the checksum lookup itself is skipped) |

Environment variables: `ISONGWRT_SOURCE`, `ISONGWRT_GH_PROXY`, `ISONGWRT_CHECKSUM`,
`ISONGWRT_SS2022_PORT`, `ISONGWRT_SMARTDNS_PORT`, `ISONGWRT_SMARTDNS_UPSTREAMS`,
`ISONGWRT_NTP_*`, `ISONGWRT_SRV_USER`, `ISONGWRT_SRV_GROUP`, and the path overrides
`ISONGWRT_BIN`, `ISONGWRT_CONF_DIR`, `ISONGWRT_WORK_DIR`, `ISONGWRT_DATA_DIR`,
`ISONGWRT_BACKUP_DIR`, `ISONGWRT_LEGACY_DATA_DIR`, `ISONGWRT_LEGACY_BACKUP_DIR`,
`ISONGWRT_UNIT_FILE`, `ISONGWRT_SMARTDNS_CONF`, `ISONGWRT_SMARTDNS_ENVFILE`.

## Integrity

Upstream does not publish a checksums file for the release assets, so the script
resolves the expected sha256 in this order and stops before installing anything when
a downloaded asset does not match:

1. `--checksum` / `ISONGWRT_CHECKSUM`, when given;
2. a checksums file published next to the asset (supported for the day upstream adds one);
3. the sha256 digest of the asset from the GitHub release API (unauthenticated calls
   are rate limited, so this can fail on a shared IP);
4. the sha256 table pinned inside the script for the versions it ships with.

If none of them yields a digest the install **fails closed** with instructions: pass
`--checksum <sha256>` computed on a trusted host, or accept the risk explicitly with
`--allow-unverified`. Every result is printed:

```
[isongwrt] checksum source: pinned table
[isongwrt]   expected sha256: 3b795e27…
[isongwrt]   actual   sha256: 3b795e27…
[isongwrt] checksum OK: sing-box-1.15.0-alpha.6-linux-amd64-glibc.tar.gz
```

Downloads through a third-party accelerator (`--source mirror`, or the automatic
fallback of `--source auto`) print a prominent warning and are recorded in
`deploy-record.json` (`download_source`, `mirror_used`). Production hosts should use
`--source direct`, or `--source mirror --checksum <sha256>` when GitHub is unreachable.

## Verify

```sh
/usr/local/bin/sing-box version
systemctl status sing-box --no-pager
ss -tlnp | grep 15835
/usr/local/bin/sing-box check -D /var/lib/sing-box -C /etc/sing-box/conf
journalctl -u sing-box -n 50 --no-pager | grep -E 'FATAL|ERROR'
```

The script's own health check is anchored to the start it just performed: the
listening socket on the port must belong to the unit's current `MainPID`, and only
`FATAL` lines since `ExecMainStartTimestamp` fail the check. `ERROR` lines about
rule-set downloads are background retries and are harmless. Traffic works end to end
when the log shows `inbound/shadowsocks[ss-in]: inbound multiplex connection to …`.

## Config files

`/etc/sing-box/conf/` is loaded with `sing-box run -D /var/lib/sing-box -C /etc/sing-box/conf`.

| File | Content |
|---|---|
| `00_log.json` | `log.level = info` |
| `01_inbounds.json` | ss2022 inbound: `listen: "::"`, port, key, `multiplex` |
| `02_outbounds.json` | `direct` |
| `03_route.json` | `sniff`, rejects (BT / ads / private / geoip-cn), `final: direct`, `http_clients` |
| `04_dns.json` | `8.8.8.8` + `1.1.1.1`, or smartdns on `127.0.0.1:6053` |
| `05_ntp.json` | built-in NTP client (removed when `--no-ntp` is used) |

Permissions: `/etc/sing-box` and `/etc/sing-box/conf` are `750 root:sing-box` and the
shards are `640 root:sing-box`; the key and the records are `600 root:root`. The
config tree is deliberately **not** owned by the service: a compromised sing-box must
not be able to rewrite the configuration it is started from. Runtime state (including
`cache.db`) lives in `/var/lib/sing-box`, which is `750 sing-box:sing-box`.

The systemd unit runs as `User=sing-box` with `NoNewPrivileges`, `ProtectSystem=strict`
(with `ReadWritePaths=/var/lib/sing-box`), `PrivateTmp`, `ProtectHome` and an empty
`CapabilityBoundingSet` (`CAP_SYS_TIME` is added only for `--ntp-write-system`).

### smartdns (`--with-smartdns`)

The distribution file `/etc/smartdns/smartdns.conf` is a dpkg conffile and is
**left untouched** (it ships no upstream servers and binds `[::]:53`). Instead:

| File | Change |
|---|---|
| `/etc/smartdns/isongwrt.conf` | created: `bind 127.0.0.1:6053`, `bind-tcp` same port, speed check, cache, prefetch, serve-expired, upstreams |
| `/etc/default/smartdns` | one line: `SMART_DNS_OPTS="-c /etc/smartdns/isongwrt.conf"` (original kept as `.isongwrt-orig`) |

A systemd drop-in cannot be used here: the unit's `EnvironmentFile` takes precedence
over `Environment=`, and an unquoted value would be split at spaces. Loopback-only
binding keeps smartdns off port 53 and off the public network. `uninstall` restores
`/etc/default/smartdns` from `.isongwrt-orig` and removes the generated file; the
smartdns package itself is left installed.

## Reconciliation with a pre-existing deployment

The defaults below describe a host that was deployed earlier and is still running
the layout of that time. Running `install`/`upgrade` on such a host changes three
things at once, so check them deliberately:

| Aspect | Earlier deployment | Script default now |
|---|---|---|
| Shards | `01_inbounds`, `02_outbounds`, `03_route`, `04_dns` (4 files) | `00_log`, `01`–`04` **plus `05_ntp.json`** |
| NTP | not configured | built-in NTP client **on** (`--no-ntp` removes the shard again) |
| Core | `v1.15.0-alpha.5` built from source | official release binary, `-glibc` asset on Debian/Ubuntu |
| Working directory | `/etc/sing-box` (`-D`) | `/var/lib/sing-box` (state), config stays in `/etc/sing-box/conf` |
| Data / backup dirs | a differently named layout from an earlier revision | `/var/lib/isongwrt` and `/var/backups/isongwrt` |

Migration steps:

1. Back up `/etc/sing-box` and note the running core version.
2. If the host still has the old data directory (with `ss2022.password`), either copy
   the key to `/var/lib/isongwrt/ss2022.password` or export
   `ISONGWRT_LEGACY_DATA_DIR=<old directory>` — otherwise a **new key is generated**
   and every client must be updated. The script's own legacy defaults are
   `/var/lib/isongwrt-legacy` and `/var/backups/isongwrt-legacy`, which `rollback`
   searches automatically (`ISONGWRT_LEGACY_BACKUP_DIR` overrides that).
3. Run `install --dry-run` first and compare the printed plan with the table above.
4. Decide explicitly: keep the 4-shard layout with `--no-ntp` (closest to the old
   host), or adopt the default 6-file layout and accept the added NTP shard.
5. Run `install` (not `upgrade`) so the config is regenerated, then `check` and
   `status`; `rollback` restores the newest binary and config backup if the health
   check fails.

## Feed trust model (client side)

The LuCI feed is a separate concern from this script, but the two are often confused:

- the `openwrt-24.10` (opkg) index is signed with usign and the feed publishes
  `key-build.pub`, which `feed.sh` installs with `opkg-key add` (trust on first use:
  key and index come from the same host);
- the `openwrt-25.12` (apk) index is **not signed** — no apk public key is published —
  so installing from it requires `--allow-untrusted`, which `install.sh`/`feed.sh`
  pass automatically and report.

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
- `--role` is a record field today. Do not assume role-specific hardening.
- Every downloaded asset is checksum-verified before it is executed, including when a
  third-party accelerator is used; the accelerator itself is never trusted.

## FAQ

**Download fails on a server in CN** — use `--source mirror --gh-proxy <https prefix>`
(announced as third-party, still checksum-verified), or download the tarball elsewhere
and pass `--binary` (combine with `--checksum` to have it verified).

**"no checksum available for …"** — the release metadata could not be reached (rate
limit/offline) and the version is not in the pinned table. Pass
`--checksum <sha256>` computed on a trusted host, or `--allow-unverified` if you
really accept unverified content.

**Port already in use** — `ss -tlnp | grep <port>`; pick another `--listen-port`.

**Why is there no fake-ip or rule-set routing on the server?** Routing is done by
the clients; the server stays simple and only rejects traffic it should not carry.

**Why not use the official `.deb`?** It ships a single-file config and its own unit,
which does not fit the shard layout used here. Pick one; this script does not manage
that path.

**Does `--dry-run` change anything?** No: no config, key, unit or service change.
Version resolution and the download still run so the URLs can be checked; the checksum
lookup itself only happens on a real install.
