# rules

Rule sets shipped with this repository. They are **generated outside this repository**
(see *Generation and review* below) and committed in both formats.

| File | Content | Source |
|---|---|---|
| `cn-extra.json` | human-readable source: domains that resolve inside CN but are absent from the public lists (used for direct routing + real-IP DNS) | auto-discovered by the maintainer's tooling |
| `cn-extra.srs` | sing-box binary rule set, compiled from the `.json` above | `sing-box rule-set compile cn-extra.json` |

Both files are committed in the same change; never update one without the other.

## echsdirect / echsdirectip (upstream echs-top lists)

Two more generated rule sets ship here, produced by CI from the public echs-top lists:

| File | Content | Source |
|---|---|---|
| `echsdirect.json` / `.srs` | ECH direct domains — 32 536 `domain_suffix` + 105 exact `domain` | `raw.githubusercontent.com/echs-top/proxy/main/list/domain/direct.list` |
| `echsdirectip.json` / `.srs` | ECH direct IP ranges — 9 971 `ip_cidr` | `raw.githubusercontent.com/echs-top/proxy/main/list/ip/direct.list` |
| `manifest-echs.json` | provenance: source URLs, `generated_at`, counts, per-file `sha256`, delta vs the previous release | — |

Pipeline: `.github/workflows/rules-echs.yml` (daily `schedule` + `workflow_dispatch`)
→ downloads the lists → `scripts/convert-echs-lists.py` (parse → guardrails → compile with a
**pinned** sing-box) → `scripts/verify-echs-parity.py` (parity gate against the previous release)
→ commits the artifacts. Fail-closed: any guardrail or compile failure publishes nothing and the
previous artifacts stay in place.

Guardrails (measured, not guessed):

* empty set → rejected (both sets);
* **domain set**: "only grows" — upstream churn is additive (measured +34, 0 removals);
* **IP-CIDR set**: must **not** be "only grows" — upstream legitimately shrinks (measured −14,
  i.e. −0.14%), so the gate rejects only a shrink larger than 10%;
* compile failure → abort; and identical inputs produce byte-identical artifacts (no daily noise commits).

Reproduce locally:

```sh
curl -fsSL -o /tmp/domain.list https://raw.githubusercontent.com/echs-top/proxy/main/list/domain/direct.list
curl -fsSL -o /tmp/ip.list     https://raw.githubusercontent.com/echs-top/proxy/main/list/ip/direct.list
python3 scripts/convert-echs-lists.py --out-dir rules --domain-file /tmp/domain.list --ip-file /tmp/ip.list \
        --sing-box /path/to/sing-box --baseline-dir rules
python3 scripts/verify-echs-parity.py --old-dir <previous> --new-dir rules --sing-box /path/to/sing-box
```

> Client-side note: these two sets are referenced from clients as `type: remote` **with an explicit
> `http_client`** (jsDelivr primary, `raw.githubusercontent.com` fallback). A `http_client` whose
> `detour` points at a `direct`-type outbound is rejected in sing-box 1.15
> (`detour to an empty direct outbound makes no sense`), and omitting the client is fatal too.

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
