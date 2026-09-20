# rules

Rule sets shipped with this repository. They are **generated outside this repository**
(see *Generation and review* below) and committed in both formats.

| File | Content | Source |
|---|---|---|
| `cn-extra.json` | human-readable source: domains that resolve inside CN but are absent from the public lists (used for direct routing + real-IP DNS) | auto-discovered by the maintainer's tooling |
| `cn-extra.srs` | sing-box binary rule set, compiled from the `.json` above | `sing-box rule-set compile cn-extra.json` |

Both files are committed in the same change; never update one without the other.

## Client usage

Reference the rule set from `route.rule_set`. Since sing-box 1.14 the download
client is defined **once at the top level** (`http_clients`) and referenced by the
rule set through `http_client`:

```json
{
  "http_clients": [
    { "tag": "proxy-client", "detour": "proxy" }
  ],
  "route": {
    "rule_set": [
      { "type": "remote", "tag": "cn-extra", "format": "binary",
        "url": "https://cdn.jsdelivr.net/gh/c000127/isongwrt@main/rules/cn-extra.srs",
        "update_interval": "1d", "http_client": "proxy-client" }
    ]
  }
}
```

Replace `proxy` with the tag of your own proxy outbound. jsDelivr is the primary
source; `https://raw.githubusercontent.com/c000127/isongwrt/main/rules/cn-extra.srs`
is the fallback for networks where jsDelivr is unreachable.

> The legacy per-rule-set `download_detour` option is deprecated in sing-box 1.14.0
> and **fatal at runtime** on 1.15.x (`FATAL: to continuing using this feature, set
> environment variable ENABLE_DEPRECATED_LEGACY_RULE_SET_DOWNLOAD_DETOUR=true`).
> Do not use it. Note that `sing-box check` does *not* catch this — only `run` does.

> jsDelivr caches branch references for about 12 h, so a freshly pushed rule set can
> lag behind `main`. If you need it immediately, install/refresh through
> `--source=direct` or point the URL at the `raw.githubusercontent.com` fallback.

## Generation and review

- **Criteria**: a domain is added only when both the direct (CN) resolver and the
  clean resolver used through the proxy agree that it is served from inside CN. A
  domain that fails either check is not added.
- **Review rule**: *when evidence is insufficient, keep the entry*. Ambiguous
  domains stay in the set — a false negative (a CN domain routed through the proxy)
  costs a slow connection, a false positive breaks a domestic service.
- **Reproducibility**: `cn-extra.srs` is compiled with
  `sing-box rule-set compile cn-extra.json` using **sing-box 1.15.0-alpha.6**.
  Compiling the committed `.json` with that version reproduces the committed `.srs`
  byte for byte (sha256
  `a97e3718ea4d9b89258d074454f699d8c905d6898a4caf1659358af22fb0dc35`); a different
  compiler version may produce a different byte stream.
- **Verification**: `sing-box rule-set decompile cn-extra.srs` must list exactly the
  rules present in `cn-extra.json`.
- **Last reviewed**: 2026-09-19/20 (entries `yostar.net`, `open.yostar.net`,
  `udata-api.open.yostar.net`, `customer.yostar.net`, `daguoxiaoxian.com`).

> `sing-box rule-set decompile` writes `"version": 2`; the JSON schema version of the
> source file may differ. This asymmetry is expected and harmless — the compiled
> `.srs` is the artifact that matters, and `compile` produces a byte-identical `.srs`
> from either form. Always judge consistency by the `compile` result, not by the
> `version` field of a decompiled file.
