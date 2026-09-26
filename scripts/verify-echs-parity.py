#!/usr/bin/env python3
"""verify-echs-parity —— 比对两版 echs 规则集（旧 vs 新）的等价性，输出可复核的 JSON 报告。

做三件事：
  1. 条目数比对（domain_suffix / domain / ip_cidr），列出新增/删除；
  2. 用 `sing-box rule-set match`（**结果走 stderr**）对**编译后的 .srs** 抽样逐条判定；
  3. 把工具判定与本地"集合模型"对照：只在模型预期一致处要求新旧一致，
     对"新增/删除"样本要求**预期的不对称**（这正是差异的解释）。

抽样规则（固定随机种子，可复现）：
  * 交集样本 ×N：模型预期新旧都必须命中；
  * 新增样本 ×N：模型预期"新命中、旧不命中"（若被其它后缀/网段覆盖则按模型记录，不算失败）；
  * 删除样本 ×N：模型预期"旧命中、新不命中"（同上）；
  * 负对照 ×5：模型预期新旧都不命中。

用法：
  verify-echs-parity.py --old-dir DIR --new-dir DIR [--sing-box BIN] [--samples 20] [--report FILE]
退出码：0 = 全绿；1 = 存在不一致；2 = 用法/解析错误。
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import random
import subprocess
import sys
from pathlib import Path

SEED = 20260926


def load_sets(d: Path) -> dict:
    dom = json.loads((d / "echsdirect.json").read_text(encoding="utf-8"))
    ip = json.loads((d / "echsdirectip.json").read_text(encoding="utf-8"))
    suf = set(next((r["domain_suffix"] for r in dom["rules"] if "domain_suffix" in r), []))
    exact = set(next((r["domain"] for r in dom["rules"] if "domain" in r), []))
    cidr = set(next((r["ip_cidr"] for r in ip["rules"] if "ip_cidr" in r), []))
    return {"suffix": suf, "exact": exact, "cidr": cidr}


def dom_model(s: dict, d: str) -> bool:
    d = d.lower()
    if d in s["exact"]:
        return True
    return any(d == suf or d.endswith("." + suf) for suf in s["suffix"])


def ip_model(s: dict, addr: str) -> bool:
    a = ipaddress.ip_address(addr)
    for c in s["cidr"]:
        try:
            if a in ipaddress.ip_network(c, strict=False):
                return True
        except ValueError:
            continue
    return False


def tool_match(binary: str, srs: Path, query: str) -> bool:
    """`rule-set match` 的结果写在 stderr：命中时有 'match rules.[..]'，未命中时为空。"""
    r = subprocess.run([binary, "rule-set", "match", "-f", "binary", str(srs), query],
                       capture_output=True, text=True)
    return "match rules" in (r.stderr or "")


def probe_ip_for(cidr: str, other: set[str]) -> str | None:
    """取一个"只被该 cidr 覆盖、不被 other 中任何网段覆盖"的地址（保证判定可归因）。"""
    net = ipaddress.ip_network(cidr, strict=False)
    cands = [net.network_address, net.broadcast_address if net.version == 4 else net.network_address]
    if net.num_addresses > 2:
        cands.append(net.network_address + 1)
    for a in cands:
        if not any(a in ipaddress.ip_network(c, strict=False) for c in other if _same_version(c, a)):
            return str(a)
    return None


def _same_version(c: str, a) -> bool:
    try:
        return ipaddress.ip_network(c, strict=False).version == a.version
    except ValueError:
        return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="两版 echs 规则集等价性比对")
    ap.add_argument("--old-dir", required=True)
    ap.add_argument("--new-dir", required=True)
    ap.add_argument("--sing-box", default="sing-box")
    ap.add_argument("--samples", type=int, default=20)
    ap.add_argument("--report", default=None)
    a = ap.parse_args(argv)

    old_dir, new_dir = Path(a.old_dir), Path(a.new_dir)
    # 预检：两个目录都必须同时具备 source JSON 与编译产物；缺 .srs 会让 match 全部判为"不命中"
    # 从而产生一整片假差异（实测踩过），所以这里直接报错退出，而不是给出一份误导性的报告。
    need = ["echsdirect.json", "echsdirect.srs", "echsdirectip.json", "echsdirectip.srs"]
    for d in (old_dir, new_dir):
        missing = [f for f in need if not (d / f).is_file()]
        if missing:
            print(f"{d}: 缺少 {missing} —— 无法比对（.srs 缺失会让全部 match 判定为不命中）", file=sys.stderr)
            return 2
    old, new = load_sets(old_dir), load_sets(new_dir)
    rnd = random.Random(SEED)
    fail: list[str] = []
    report: dict = {"old_dir": str(old_dir), "new_dir": str(new_dir), "seed": SEED, "samples": a.samples,
                    "counts": {}, "probes": []}

    for key, label in (("suffix", "domain_suffix"), ("exact", "domain"), ("cidr", "ip_cidr")):
        report["counts"][label] = {"old": len(old[key]), "new": len(new[key]),
                                   "added": len(new[key] - old[key]), "removed": len(old[key] - new[key])}

    common_d = sorted(old["suffix"] & new["suffix"]) + sorted(old["exact"] & new["exact"])
    added_d = sorted(new["suffix"] - old["suffix"]) + sorted(new["exact"] - old["exact"])
    removed_d = sorted(old["suffix"] - new["suffix"]) + sorted(old["exact"] - new["exact"])
    rnd.shuffle(common_d)
    probes_d = ([("common", d) for d in common_d[:a.samples]] +
                [("added", d) for d in added_d[:a.samples]] +
                [("removed", d) for d in removed_d[:a.samples]] +
                [("negative", f"zz-parity-neg-{i}.notarealtld-xyz") for i in range(5)])

    for kind, q in probes_d:
        o, n = tool_match(a.sing_box, old_dir / "echsdirect.srs", q), tool_match(a.sing_box, new_dir / "echsdirect.srs", q)
        mo, mn = dom_model(old, q), dom_model(new, q)
        ok = (o == mo and n == mn) and (o == n if kind == "common" else True)
        if kind == "negative":
            ok = (not o and not n)
        rec = {"set": "echsdirect", "kind": kind, "query": q, "old_match": o, "new_match": n,
               "old_model": mo, "new_model": mn, "ok": ok}
        report["probes"].append(rec)
        if not ok:
            fail.append(f"echsdirect/{kind}: {q} old={o} new={n} (model old={mo} new={mn})")

    ips_common = sorted(old["cidr"] & new["cidr"])
    ips_added = sorted(new["cidr"] - old["cidr"])
    ips_removed = sorted(old["cidr"] - new["cidr"])
    rnd.shuffle(ips_common)
    probes_i = []
    for kind, pool in (("common", ips_common), ("added", ips_added), ("removed", ips_removed)):
        picked = 0
        for c in pool:
            if picked >= a.samples:
                break
            other = (old["cidr"] | new["cidr"]) - {c}
            addr = probe_ip_for(c, other)
            if not addr:                      # 被其它网段完全遮蔽：无法归因，跳过并记录
                report["probes"].append({"set": "echsdirectip", "kind": kind, "query": c,
                                         "skipped": "被其它网段完全覆盖，无法归因", "ok": True})
                continue
            probes_i.append((kind, c, addr))
            picked += 1
    probes_i += [("negative", None, "8.8.8.8")]
    for kind, cidr, addr in probes_i:
        o = tool_match(a.sing_box, old_dir / "echsdirectip.srs", addr)
        n = tool_match(a.sing_box, new_dir / "echsdirectip.srs", addr)
        mo, mn = ip_model(old, addr), ip_model(new, addr)
        ok = (o == mo and n == mn) and (o == n if kind == "common" else True)
        if kind == "negative":
            ok = (not o and not n)
        report["probes"].append({"set": "echsdirectip", "kind": kind, "query": f"{addr} ({cidr or 'negative'})",
                                 "old_match": o, "new_match": n, "old_model": mo, "new_model": mn, "ok": ok})
        if not ok:
            fail.append(f"echsdirectip/{kind}: {addr} ({cidr}) old={o} new={n} (model old={mo} new={mn})")

    report["failed"] = fail
    report["ok"] = not fail
    text = json.dumps(report, ensure_ascii=False, indent=1)
    if a.report:
        Path(a.report).write_text(text + "\n", encoding="utf-8")
    print(text)
    if fail:
        print(f"\n✗ {len(fail)} 处不一致", file=sys.stderr)
        return 1
    probed = [p for p in report["probes"] if not p.get("skipped")]
    skipped = [p for p in report["probes"] if p.get("skipped")]
    print(f"\n✓ 全绿：{len(probed)} 个抽样探针（common/added/removed/negative）逐个一致；"
          f"另有 {len(skipped)} 个样本因被其它网段完全覆盖、无法单点归因，已记录跳过（无语义影响）",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
