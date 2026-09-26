#!/usr/bin/env python3
"""convert-echs-lists —— 把 echs-top 的两条公开列表转成 sing-box 规则集并编译为 `.srs`。

上游（公开、纯文本，无凭据）：
  * 域名集  https://raw.githubusercontent.com/echs-top/proxy/main/list/domain/direct.list
            格式：`+.example.com`（后缀）/ `example.com`（精确）/ `*`（占位行，忽略）
  * IP 段集 https://raw.githubusercontent.com/echs-top/proxy/main/list/ip/direct.list
            格式：每行一个 CIDR（v4 + v6）

产物（写入 `--out-dir`，默认 `rules/`）：
  * echsdirect.json / echsdirect.srs      source JSON v3 → 二进制规则集
  * echsdirectip.json / echsdirectip.srs
  * manifest-echs.json                    溯源：source_url / generated_at / counts / sha256 / 与上一版的差异

设计要点：
  1. **先全绿再落地**：全部产物先写临时目录、编译成功后才原子替换进 `--out-dir`；
     任一护栏或编译失败 → 非 0 退出且**旧产物原样保留**（"不发布"语义）。
  2. **护栏按实测设计**（2026-09-26 实测：上游域名集 +35、IP 段集 −14）：
     - 空集拒绝（域名集与 IP 段集都必须非空）；
     - **域名集**默认"只增不减"（`--allow-domain-loss` 可关）；
     - **IP 段集不得用只增不减**：缩小超过 `--max-ip-shrink-pct`（默认 10%）才拒绝；
     - 解析行数统计进 manifest，格式突变会以"未解析行数"暴露。
  3. 排序与旧产物一致（字符串序），便于 diff 与人工复核。

用法：
  convert-echs-lists.py [--out-dir DIR] [--sing-box BIN]
                        [--domain-file F] [--ip-file F]        # 离线/CI 已下载的文件；缺省则联网抓取
                        [--skip-compile] [--allow-domain-loss] [--max-ip-shrink-pct N]
                        [--baseline-dir DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

SOURCE_DOMAIN = "https://raw.githubusercontent.com/echs-top/proxy/main/list/domain/direct.list"
SOURCE_IP = "https://raw.githubusercontent.com/echs-top/proxy/main/list/ip/direct.list"
UA = "isongwrt-rules-echs/1.0 (+https://github.com/c000127/isongwrt)"

DOMAIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$")
# 后缀允许**单标签**（上游确有 `+.cn` / `+.baidu` 这类基础条目，占 58 条；sing-box 的
# domain_suffix 本身支持单标签）。旧转换器对这些行不做校验，新实现若强制"必须含点"会误删它们
# → 与现网 .srs 不等价（正好会被"只增不减"护栏拦住）。因此这里只做形状校验，不要求含点。
SUFFIX_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*$")
CIDR_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$|^[0-9A-Fa-f:]+/\d{1,3}$")


# ────────────────────────── 输入 ──────────────────────────
def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


def read_input(url: str, path: str | None) -> tuple[str, str]:
    if path:
        return Path(path).read_text(encoding="utf-8", errors="replace"), f"file:{path}"
    return fetch(url), url


# ────────────────────────── 解析 ──────────────────────────
def parse_domains(text: str) -> dict:
    suffix, exact, skipped = [], [], []
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s == "*" or s.startswith("#") or s.startswith("//"):
            continue
        if s.startswith("+.") or s.startswith("*."):
            v = s[2:].strip().lower()
            (suffix if SUFFIX_RE.match(v) else skipped).append(v)
        elif s.startswith("."):
            v = s[1:].strip().lower()
            (suffix if SUFFIX_RE.match(v) else skipped).append(v)
        elif DOMAIN_RE.match(s):
            exact.append(s.lower())
        else:
            skipped.append(s)
    return {"domain_suffix": sorted(set(suffix)), "domain": sorted(set(exact)), "skipped": skipped}


def parse_ips(text: str) -> dict:
    cidr, skipped = [], []
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        (cidr if CIDR_RE.match(s) else skipped).append(s)
    return {"ip_cidr": sorted(set(cidr)), "skipped": skipped}


# ────────────────────────── 护栏 ──────────────────────────
class GuardError(SystemExit):
    def __init__(self, msg: str):
        super().__init__(f"GUARDRAIL: {msg}")


def guard(new: dict, prev: dict | None, max_ip_shrink_pct: float, allow_domain_loss: bool) -> dict:
    """返回 manifest 里要记录的 delta 信息；任一护栏不过就抛 GuardError（调用方保证不落地）。"""
    n_suf, n_ex = len(new["domain_suffix"]), len(new["domain"])
    n_ip = len(new["ip_cidr"])
    if n_suf == 0:
        raise GuardError("域名后缀集为空（上游格式可能已变）——拒绝发布")
    if n_ex == 0:
        raise GuardError("精确域名集为空（上游格式可能已变）——拒绝发布")
    if n_ip == 0:
        raise GuardError("IP 段集为空（上游格式可能已变）——拒绝发布")
    delta = {"domain_suffix": None, "domain": None, "ip_cidr": None}
    if prev:
        p_suf, p_ex = prev["domain_suffix"], prev["domain"]
        p_ip = prev["ip_cidr"]
        delta = {"domain_suffix": n_suf - p_suf, "domain": n_ex - p_ex, "ip_cidr": n_ip - p_ip}
        if not allow_domain_loss:
            if n_suf < p_suf:
                raise GuardError(f"域名后缀集缩水：{p_suf} → {n_suf}（域名集默认只增不减，"
                                 f"确需接受请显式加 --allow-domain-loss）")
            if n_ex < p_ex:
                raise GuardError(f"精确域名集缩水：{p_ex} → {n_ex}（同上）")
        # IP 段集：**不得**只增不减（实测会自然缩小）；只拦"缩水超过阈值"
        if p_ip and n_ip < p_ip:
            shrink = (p_ip - n_ip) * 100.0 / p_ip
            if shrink > max_ip_shrink_pct:
                raise GuardError(f"IP 段集缩水 {shrink:.2f}% > {max_ip_shrink_pct}%：{p_ip} → {n_ip}")
        if p_ip and n_ip < p_ip:
            delta["ip_shrink_pct"] = round((p_ip - n_ip) * 100.0 / p_ip, 3)
    return delta


def load_previous(baseline_dir: Path | None) -> dict | None:
    """上一版产物作为护栏基线（没有就跳过基线类护栏，仅保留空集护栏）。"""
    if not baseline_dir:
        return None
    d, i = baseline_dir / "echsdirect.json", baseline_dir / "echsdirectip.json"
    if not (d.exists() and i.exists()):
        return None
    dj, ij = json.loads(d.read_text(encoding="utf-8")), json.loads(i.read_text(encoding="utf-8"))
    return {
        "domain_suffix": len(next((r["domain_suffix"] for r in dj["rules"] if "domain_suffix" in r), [])),
        "domain": len(next((r["domain"] for r in dj["rules"] if "domain" in r), [])),
        "ip_cidr": len(next((r["ip_cidr"] for r in ij["rules"] if "ip_cidr" in r), [])),
    }


# ────────────────────────── 输出 ──────────────────────────
def build_sources(new: dict) -> dict[str, dict]:
    return {
        "echsdirect": {"version": 3, "rules": [
            {"domain_suffix": new["domain_suffix"]},
            {"domain": new["domain"]},
        ]},
        "echsdirectip": {"version": 3, "rules": [{"ip_cidr": new["ip_cidr"]}]},
    }


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="echs-top 列表 → sing-box 规则集（含护栏与编译）")
    ap.add_argument("--out-dir", default="rules", help="产物目录（默认 rules/）")
    ap.add_argument("--baseline-dir", default=None, help="上一版产物目录（默认取 --out-dir 自己）")
    ap.add_argument("--sing-box", default=os.environ.get("SING_BOX_BIN", "sing-box"), help="sing-box 可执行文件")
    ap.add_argument("--domain-file", default=None, help="已下载的域名列表（缺省联网抓取）")
    ap.add_argument("--ip-file", default=None, help="已下载的 IP 列表（缺省联网抓取）")
    ap.add_argument("--skip-compile", action="store_true", help="只产出 .json（调试用）")
    ap.add_argument("--allow-domain-loss", action="store_true", help="允许域名集缩水（默认不允许）")
    ap.add_argument("--max-ip-shrink-pct", type=float, default=10.0, help="IP 段集允许的最大缩水百分比（默认 10）")
    ap.add_argument("--dry-run", action="store_true", help="只做转换+护栏，不写盘、不编译")
    a = ap.parse_args(argv)

    out_dir = Path(a.out_dir)
    baseline_dir = Path(a.baseline_dir) if a.baseline_dir else out_dir

    dom_text, dom_src = read_input(SOURCE_DOMAIN, a.domain_file)
    ip_text, ip_src = read_input(SOURCE_IP, a.ip_file)
    new = {**parse_domains(dom_text), **parse_ips(ip_text)}
    prev = load_previous(baseline_dir)
    delta = guard(new, prev, a.max_ip_shrink_pct, a.allow_domain_loss)

    summary = {
        "ok": True,
        "counts": {"domain_suffix": len(new["domain_suffix"]), "domain": len(new["domain"]),
                   "ip_cidr": len(new["ip_cidr"])},
        "previous": prev,
        "delta": delta,
        "skipped": {"domain": len(new["skipped"]), "ip": len(new["skipped"])},
        "sources": {"domain": dom_src, "ip": ip_src},
    }
    if a.dry_run:
        summary["dry_run"] = True
        print(json.dumps(summary, ensure_ascii=False, indent=1))
        return 0

    sources = build_sources(new)
    # 幂等性：输入（规则内容）不变 → 产物逐字节不变（沿用上一版生成时间），避免 CI 每天产出"只改时间戳"的提交
    inputs_sha = hashlib.sha256(json.dumps(sources, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    prev_manifest = None
    if baseline_dir and (baseline_dir / "manifest-echs.json").exists():
        try:
            prev_manifest = json.loads((baseline_dir / "manifest-echs.json").read_text(encoding="utf-8"))
        except Exception:
            prev_manifest = None
    same_inputs = bool(prev_manifest) and prev_manifest.get("inputs_sha256") == inputs_sha
    # 先在临时目录里全部做出来（写盘 + 编译），全绿才搬进 out_dir —— 失败时旧产物原样保留
    with tempfile.TemporaryDirectory(prefix="echs-build-") as tmp:
        tmpd = Path(tmp)
        produced: dict[str, Path] = {}
        for name, doc in sources.items():
            p = tmpd / f"{name}.json"
            p.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
            produced[f"{name}.json"] = p
        if not a.skip_compile:
            for name in sources:
                src, dst = tmpd / f"{name}.json", tmpd / f"{name}.srs"
                r = subprocess.run([a.sing_box, "rule-set", "compile", str(src), "--output", str(dst)],
                                   capture_output=True, text=True)
                if r.returncode != 0 or not dst.exists() or dst.stat().st_size == 0:
                    print(f"COMPILE FAILED ({name}): {(r.stderr or r.stdout or '').strip()[-400:]}", file=sys.stderr)
                    print("→ 不发布：保留旧产物", file=sys.stderr)
                    return 2
                produced[f"{name}.srs"] = dst

        manifest = {
            "generated_at": (prev_manifest.get("generated_at") if same_inputs else
                             time.strftime("%Y-%m-%dT%H:%M:%SZ",
                                           time.gmtime(int(os.environ.get("SOURCE_DATE_EPOCH", time.time()))))),
            "inputs_sha256": inputs_sha,
            "unchanged_since": prev_manifest.get("unchanged_since") or prev_manifest.get("generated_at") if same_inputs else None,
            "generator": "scripts/convert-echs-lists.py",
            "source_url": {"echsdirect": SOURCE_DOMAIN, "echsdirectip": SOURCE_IP},
            "compiler": os.path.basename(a.sing_box),
            "counts": summary["counts"],
            "previous": prev,
            "delta": delta,
            "unparsed_lines": summary["skipped"],
            "files": {},
        }
        for fn, p in sorted(produced.items()):
            manifest["files"][fn] = {"sha256": sha256(p), "bytes": p.stat().st_size}
        mp = tmpd / "manifest-echs.json"
        mp.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        produced["manifest-echs.json"] = mp

        out_dir.mkdir(parents=True, exist_ok=True)
        for fn, p in produced.items():
            target = out_dir / fn
            tmp_target = target.with_suffix(target.suffix + ".new")
            tmp_target.write_bytes(p.read_bytes())
            os.replace(tmp_target, target)
        summary["written"] = sorted(produced)
        summary["manifest"] = manifest
    print(json.dumps(summary, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
