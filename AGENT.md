# AGENT.md — working conventions for this repository

> Scope: **this repository only** (`isongwrt` — a small LuCI app that manages a sing-box core on
> OpenWrt / iStoreOS). Host-level rules and other private repositories have their own conventions;
> they are not restated here.
> This file is **environment-agnostic**: roles, not addresses. Device-specific values belong in
> private notes, never here. Terminology: see §12.
> Status: **committed** — this file is tracked and reviewed like any other artifact in the repository.

## 1. Purpose and goals

**What it is**: a small, auditable LuCI app that installs and switches the sing-box core, manages
config files, controls the service, shows logs, and serves the official web dashboard.
**What it is not**: not a bundle, not a proxy implementation, not a kernel/TCP tuner, not a config
generator for users, no telemetry, **no Clash compatibility layer** (decision of 2026-09-20: the
management plane is sing-box's native `services.api` only — no `clash_api` option, no Clash-style
panel support). This is a **public repository** — public artifacts stay **English and minimal**,
deliberately low-key.

**Three-layer goals** (each depends on the one below):

1. **Usable** — install / switch / roll back a core, manage config, start-stop, read logs, open the
   dashboard, all from LuCI; no CLI knowledge required.
2. **Maintainable** — small surface area, readable shell + JS, reviewable diffs, versioned rule sets,
   reproducible CI builds.
3. **Evolvable** — tracks upstream sing-box (including alpha) without breaking users; channel
   switching and rollback are first-class.

**Success criteria** (checkable):

- Install, upgrade and rollback each complete in **one action** on a device;
- a configuration is **validated before** the service is restarted — a broken config never reaches
  a running device;
- public artifacts (README, release notes, scripts) are English-only and minimal;
- rule sets are versioned in-repo (`json` + `.srs`) and consumable directly by clients.

**Non-goals**: covering every architecture/branch in CI; shipping a proxy core; managing kernel or
network tuning; storing user secrets in the repository.

## 2. End-to-end (one map)

> Roles only. Any device topology (single router, router + test router, other architectures) must fit
> the same map.

### 2.1 Device runtime chain

```
LuCI view (JS)  ──HTTP──►  rpcd + ACL  ──►  ctl (shell)  ──►  uci /etc/config/isongwrt
                                                                     │
                                                      procd service (/etc/init.d/isongwrt)
                                                                     │
                      core binary:  run -D <work_dir> -C <conf_dir>  (shards merged from conf dir)
                                                                     │
                   rule sets: local .srs files  |  remote .srs downloaded via an http_client
                                                                     ▼
                                                              traffic handled by the core
```

### 2.2 Build and release chain

```
source  ──►  GitHub Actions (serial: one branch at a time, avoids SDK/cache contention)
              matrix: x86_64 × { openwrt-24.10 (ipk) , openwrt-25.12 (apk) }
              trigger: push to main or a v* tag, and only when luci-app-isongwrt/** or the
                       workflow file changed (paths: filter)
              → artifacts + SHA256SUMS + feed index (Packages.gz / packages.adb)
         ──►  GitHub Release (platform table in the body; stale assets pruned)
         ──►  user installs:  install.sh  (mirror | direct | custom)
                              feed.sh     (opkg/apk feed with mirror fallbacks)
```

### 2.3 Server-side chain (shipped in `server/`)

```
server/singbox-deploy.sh  ──►  landing host: Shadowsocks 2022 inbound (+ optional smartdns, NTP)
```

### 2.4 Rule-set chain

```
rules/cn-extra.json  (source, readable/diffable)  +  rules/cn-extra.srs (binary, for clients)
        └─ clients consume the .srs via a remote rule-set entry, downloaded through a
           top-level http_client (per-rule-set download_detour is deprecated and fatal)

echs-top lists (public text)                       ─┐
  list/domain/direct.list   (+.suffix / exact)      │  conversion + guardrails + compile
  list/ip/direct.list       (CIDR)                  │  scripts/convert-echs-lists.py
        ↓ .github/workflows/rules-echs.yml          │  (daily + manual)
rules/echsdirect.{json,srs} + rules/echsdirectip.{json,srs} + rules/manifest-echs.json
        └─ parity gate before publishing: scripts/verify-echs-parity.py (vs the previous release)
```
  * Guardrails (fail-closed — on any failure **nothing is published and the old artifacts stay**):
    empty set rejected; the **domain** set is "only grows" (allow-list churn is additive);
    the **IP-CIDR** set must NOT be "only grows" — upstream legitimately shrinks (measured −14),
    so only "shrink > 10%" is rejected; a compile failure aborts.
  * Idempotent: identical inputs ⇒ byte-identical artifacts (the manifest keeps the original
    `generated_at`), so an unchanged upstream produces no commit.

**Seams — start debugging here**: `LuCI ↔ ctl` (rpcd/ACL) · `ctl ↔ uci` (option names/defaults) ·
`service ↔ core flags` (`-D`/`-C`, work dir vs conf dir) · `core ↔ remote rule-set` (download client,
update interval) · `CI ↔ release assets` (names, checksums, feed index).

## 3. Ideal end state and the path to it

### 3.1 Ideal state (what "done" looks like)

| Dimension | Ideal (checkable) |
|---|---|
| Install / upgrade | One action; channel switch (stable / rc / beta / alpha) or exact version pin; previous core retained |
| Rollback | One action; restores the previous core **and** the previous config |
| Safety | Config validated before restart; never silently overwrite files the panel does not own |
| Observability | Service status, version, config-check result and logs visible in LuCI; API/dashboard reachable on LAN with an auto-generated secret |
| Rules | Versioned in-repo; clients fetch them remotely; adding a domain is a one-line reviewable change |
| Reproducibility | CI builds the supported targets deterministically; release assets checksummed and pruned |
| Public face | English-minimal README/release notes; no secrets, no internal addresses, no telemetry |

### 3.2 Maturity levels

| Level | Criteria | Status |
|---|---|---|
| **L1 usable** | Install/switch/start/stop/logs/dashboard work on a supported device | ✅ |
| **L2 maintainable** | Small surface, documented behavior, versioned rules, checksummed releases | ✅ |
| **L3 evolvable** | Channels (stable/rc/beta/alpha) + rollback + feed for unattended updates | ✅ |
| **L4 self-checking** | Device-level smoke test in CI; drift detection between docs and implementation; signed apk feed | ⏳ not done |

### 2.5 Restart-time rule-set prefetch (B2)

```
ctl service start|restart            (the panel buttons — nothing else)
  └─ 1) ruleset-prefetch: read every route.rule_set[].type=="remote" url from the conf dir,
        fetch each one to a temp file, require non-empty
           all good  → continue with the restart
           any fail  → ABORT: exit≠0, JSON error listing the failed URLs,
                       the currently running core is left untouched
  └─ 2) escape hatches (any one skips step 1, byte-for-byte the old behaviour):
           ctl service restart --skip-prefetch
           uci set isongwrt.main.prefetch=0        (default 1)
           ISONGWRT_SKIP_PREFETCH=1 ctl service restart
```

Why it exists: **one unreachable remote rule set is fatal at startup and the warm cache does not
save you**, so a restart during a node outage would take the proxy down for as long as the outage
lasts (measured; see the homobox audit report F1). Prefetch turns that into "refuse to restart".

Deliberate detail: **boot is unaffected** — rc.common calls `start_service` in the init script
directly, so a cold boot with no WAN yet cannot be locked out by a failing prefetch. Only the
panel path is gated. `ctl ruleset-prefetch [--confdir DIR]` is also runnable on its own and is
read-only (it only writes temp files): that is how it is verified offline and against production.

### 3.3 Known gaps (explicit "do / don't")

| # | Gap | Impact | Plan |
|---|---|---|---|
| 1 | apk feed signing not enabled (SDK-side failure on 25.12) | apk users get an unsigned feed index (`--allow-untrusted` on install) | documented; revisit when the SDK side works |
| 2 | CI covers x86_64 only | other architectures build only from source or install the `Architecture: all` package from Releases | intentional (keeps CI small) |
| 3 | No device-level smoke test (install → start → check) in CI | regressions surface on devices | open |
| 4 | No CHANGELOG file (release notes are generated) | history lives in git log/releases | intentional |
| 5 | No automatic core-version bump | users pick channels manually | intentional (channels cover it) |
| 6 | `--role` in `server/singbox-deploy.sh` is **decorative** | it is recorded in the deploy record but no code path branches on it; only the `landing` role is actually implemented | documented; implement role-specific templates before claiming proxy-role support |
| 7 | smartdns integration is best-effort | `apt-get install smartdns` failure is a warning, but `systemctl restart smartdns` runs unguarded under `set -e`; the health probe is a `dig` against `127.0.0.1:6053` and only warns | open — treat a failed smartdns step as "DNS may be wrong", verify with `dig` before trusting the deployment |
| 8 | Install/upgrade health checks can leave a half-applied state | a failed check aborts after config generation; automatic rollback on install failure is not implemented yet | open — keep a backup and a rollback slot, verify with `ctl check` |
| 9 | Shell scripts are syntax-checked only, not linted | `sh -n` catches syntax errors, not logic/portability bugs | consider adding a lint gate to CI |

> Principle: **gaps are never hidden**; every "don't" keeps a written reason.

## 4. Record discipline (mandatory)

**Rule of thumb**: if it is not recorded, it did not happen. Change and record ship together.

| Carrier | What goes in it | Requirement |
|---|---|---|
| Commit | background / changes / verification / leftovers | every change, fixed structure, `type: subject` prefix |
| `README.md` | user-visible behavior, options, install paths | update whenever behavior changes |
| Release notes | platform table, install snippets, asset list (the checksums live in the attached `SHA256SUMS.txt`, not in the body) | generated by CI from the workflow |
| `rules/` | the rule sets themselves (`json` + `.srs`) | both formats in the same commit |
| Device backups | config before a risky change (`ctl config-backup`) | required before touching device state |

**Minimum sufficiency** — a reader without context must be able to answer:
**① why ② what ③ how it was verified ④ how to revert**.

**Forbidden**: assertions without evidence; changes without records; secrets (API secrets, feed keys,
private keys) in the repository; docs that contradict the implementation.

## 5. Work discipline

1. **Inspect before acting** — read the current script/view/config first; write down findings, then edit.
2. **Read before writing** — reuse existing patterns (`ctl` subcommands, uci option names, view helpers);
   do not invent parallel mechanisms.
3. **Evidence before claims** — verification means real output (on a device or in CI), not reasoning.
4. **Backup before change** — no revert path, no change (`ctl config-backup`, keep the previous core).
5. **Small and reversible** — one change at a time; never bundle unrelated edits into one release.
6. **Least disruption** — a device restart interrupts a whole network: validate first, keep the window short.
7. **Honest reporting** — failures are reported with impact and recovery, never smoothed over.
8. **Respect scope** — this repo manages the core and its config; kernel/network tuning and proxy
   protocols are out of scope.
9. **Ask when unsure** — stop and ask rather than guessing on user-visible behavior.
10. **Close the loop** — change → verify on a device → record. Unverified work is not done.

## 6. Red lines

1. **No secrets in the repository**: `api_secret`, feed signing keys and device keys stay on the
   device or in CI secrets.
2. **Never touch files this panel does not own.** If a manually installed core, service or config is
   found on a device, **report it** — do not delete or disable it silently.
3. **Every upgrade must be reversible**: keep the previous core (rollback slot) and back up config first.
4. **Validate before restart**: run the config check, and only restart on success.
5. **Public artifacts are English and minimal** — no internal addresses, no personal notes, no
   private repository or host names.
6. **CI stays small and reproducible**: no unpinned third-party build scripts, no matrix growth without
   a stated reason.
7. **No silent behavior changes**: user-visible changes are documented in README/release notes.

## 7. Platforms and roles

| Item | Value |
|---|---|
| Target systems | OpenWrt 24.10 (opkg / `ipk`) · OpenWrt 25.x (apk) · iStoreOS |
| Libc / arch | musl; the CI matrix builds x86_64 only, the package itself is `Architecture: all` |
| Roles | **device** (production / test router) · **maintainer host** (repo, scripts, releases) · **CI** · **landing host** (`server/` script) |

## 8. What the panel owns (its layout)

```
/usr/lib/isongwrt/ctl                     control script (all subcommands)
/usr/lib/isongwrt/sing-box                managed core binary (the only one this panel runs)
/etc/isongwrt/conf/                       config shards (merged by the core via -C)
/etc/isongwrt/installed/                  installed cores (rollback source)
/etc/isongwrt/backups/                    config backups
/etc/isongwrt/cache/releases.atom         cached release list (about 20 recent tags)
/etc/isongwrt/{active,previous,api-source}
/etc/config/isongwrt                      uci options (see below)
/etc/init.d/isongwrt                      procd service
htdocs/luci-static/resources/view/isongwrt/*.js    LuCI views (overview/core/config/log/dashboard)
/usr/share/luci/{menu.d,rpcd/acl.d}/               menu entry + ACL for the views
```

`/etc/isongwrt/rules/` is **not** created by this panel — local rule sets live wherever the user's
own config points at them.

Key uci options: `enabled`, `core_path`, `conf_dir`, `work_dir`, `channel`
(`stable|rc|beta|alpha`), `pin_version`, `github_proxy`, `api_listen`/`api_port`/`api_secret`,
`dashboard`, `dashboard_download_url`. The management plane is the native sing-box `services.api`
service; **there is no `clash_api` / `clash_port` / `clash_secret` option** (removed 2026-09-20).

`pin_version` and `github_proxy` are **panel-side parameters**: the Core page passes them to
`ctl install-bg <channel> <tag>`; `ctl` itself never reads the uci options.

## 9. Commands (maintainer quick reference)

```sh
# on a device
/usr/lib/isongwrt/ctl ruleset-prefetch [--confdir /etc/isongwrt/conf]   # read-only: fetch every remote rule set
/usr/lib/isongwrt/ctl status            # running state, version, config-check result
/usr/lib/isongwrt/ctl check             # validate config only
/usr/lib/isongwrt/ctl service restart   # restart the managed core
/usr/lib/isongwrt/ctl log 200           # fetch logs (returns JSON: {"ok":true,"log":"..."})
/usr/lib/isongwrt/ctl channels          # available channels
/usr/lib/isongwrt/ctl install alpha     # install a channel (or an exact tag)
/usr/lib/isongwrt/ctl rollback          # restore the previous core
/usr/lib/isongwrt/ctl config-list | config-backup | config-restore
/usr/lib/isongwrt/ctl api-sync          # (re)generate the API/dashboard shard
/usr/lib/isongwrt/ctl api-secret-new    # generate a fresh api_secret and write it to uci
/usr/lib/isongwrt/ctl conf-fix-remote   # inject the download client for remote rule sets
# repo side
sh -n install.sh && sh -n feed.sh && sh -n luci-app-isongwrt/root/usr/lib/isongwrt/ctl
sh install.sh [--source mirror|direct|custom]     # install / update the package
sh feed.sh                                        # add/refresh the package feed
```

## 10. Known pitfalls (learned the hard way)

1. The service runs the core with `-D <work_dir> -C <conf_dir>` — **the conf dir is merged**, so
   shard order and duplicate keys matter.
2. `ctl log` returns **JSON** (`{"ok":true,"log":"…"}`); parsing it as plain text yields nothing.
3. **Remote rule sets in sing-box 1.14+**: the legacy per-rule-set download-detour option is
   deprecated **and fatal at runtime** (`ENABLE_DEPRECATED_LEGACY_RULE_SET_DOWNLOAD_DETOUR` is
   required to keep using it); omitting the download client is fatal too. The correct shape is a
   top-level `http_clients` definition plus a `http_client` reference on the rule set — this panel
   injects a default one (`ctl conf-fix-remote`). `sing-box check` does **not** catch this.
4. The config **check does not validate runtime references** (e.g. HTTP client tags): a config can pass
   the check and still fail to start. Always keep a backup and a rollback path.
5. Device shells are **busybox**: no `python3`, `pgrep` has no `-c`, `pkill` is not built by default
   (use `pgrep` + `kill`), `timeout` may be missing.
6. Devices are **musl**: upstream `linux-amd64` builds are glibc and will not execute ("not found").
7. `sing-box rule-set compile` takes **one argument** and writes a sibling `.srs` file.
8. **Multiple same-named cores** may exist on a device (panel-managed vs manually installed). Confirm
   which one is actually running before drawing conclusions.
9. A leftover init script with `enabled=1` can compete with this panel at boot — detect and report,
   never remove silently (§6.2).
10. uci changes need `uci commit` before the service restart to take effect.
11. Keep a rollback slot: an upgrade without a retained previous core is not reversible.
12. Alpha-channel cores may add/remove config fields: validate against the version actually installed.
13. `sing-box rule-set decompile` emits `"version": 2` while the committed source uses `"version": 3`.
    The asymmetry is expected — `compile` produces the same `.srs` from either form.

## 11. Commits and collaboration

- Commit subject: `type: short description`, **English**. Types actually used in this repository:
  `rules`, `CI`, `docs`, `fix`, `release`, `ui`, `core`, `config`, `feat`, `build`, `install`; a large
  part of the history has no prefix at all. Prefer one of the prefixes above; keep the subject short,
  and let the body carry **background → changes → verification → leftovers** (Chinese or English).
- Behavior changes update `README.md`; rule-set changes commit `json` and `.srs` together.
- **Never write internal addresses, host names or private project names into commit messages.**
- Destructive or device-visible operations are proposed first, then executed; results are reported
  with the exact commands and observed output.
- Do not push tags or publish releases without an explicit request.

## 12. Release discipline

1. **Any change under `luci-app-isongwrt/` requires bumping `PKG_RELEASE`** (or `PKG_VERSION`) in
   `luci-app-isongwrt/Makefile` in the same commit. opkg/apk treat an unchanged version as "nothing to
   do" and will not replace the installed files — users then never receive the fix, and the release
   body's version stays stale. The Makefile carries the same note.
2. A release is published from CI only; the version in the release body is read from the Makefile, so
   the bump must land **before** the build runs.
3. `feed.sh` / `install.sh` / `ctl` changes are user-visible install paths: run `sh -n` on all three
   before pushing (CI does not lint shell yet).
4. Assets are attached to `latest` (rolling build from `main`) or to the `v*` tag; `SHA256SUMS.txt`
   ships with every release.

## 13. Glossary (this repository's wording)

| Term | Meaning here |
|---|---|
| **core** | the sing-box executable managed by this panel (`core_path`, default `/usr/lib/isongwrt/sing-box`) |
| **channel** | release track for the core: `stable` / `rc` / `beta` / `alpha`; the panel's `pin_version` field overrides it |
| **shard** | one JSON file inside `conf_dir`; the core merges the whole directory (`-C`) |
| **ctl** | the shell control script; all panel actions go through its subcommands |
| **procd** | OpenWrt's service manager; the init script supervises the core |
| **uci** | OpenWrt's configuration system (`/etc/config/isongwrt`); the panel's own options live here |
| **rpcd / ACL** | OpenWrt's RPC daemon and its access-control list; how LuCI views call `ctl` |
| **LuCI view** | the JS pages under `view/isongwrt/` (overview, core, config, log, dashboard) |
| **ipk / apk** | package formats: 24.10 uses opkg/ipk, 25.x uses apk |
| **feed** | the package index (Packages.gz / packages.adb) that `feed.sh` installs |
| **rollback slot** | the retained previous core, used by `ctl rollback` |
| **dashboard** | the official sing-box web dashboard, downloaded and served by the panel through the native `services.api` service |
| **work_dir / conf_dir** | the core's working directory (`-D`) and configuration directory (`-C`) |
| **rule set** | a sing-box rule collection; `.json` is the source format, `.srs` the binary one |
| **http_client** | a top-level sing-box 1.14+ download-client definition; remote rule sets reference it by tag |

14. **`pgrep -f <pattern> | xargs kill` self-matches** the shell that carries the pattern in its own
    command line (cost: three killed test sessions). Always scope such cleanups to processes whose
    `argv[0]`/ancestry you actually control.
15. **busybox awk: save `RLENGTH` immediately.** A second `match()` overwrites `RSTART`/`RLENGTH`,
    which silently produced an infinite loop in the rule-set URL scanner (it looked like a hang).
    The scanner now also breaks out when a scan pass made no progress.
