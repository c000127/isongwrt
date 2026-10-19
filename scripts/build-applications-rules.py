#!/usr/bin/env python3
"""Build a daily applications subset without domain substring routing."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
URL = 'https://github.com/DustinWin/ruleset_geodata/releases/download/sing-box-ruleset/applications.srs'


def sanitize(source):
    # Preserve process routing and explicit domain ownership, not name substrings.
    # package_name in this upstream currently contains macOS extensions, not SFA apps.
    allowed = {'process_name', 'domain', 'domain_suffix'}
    known = allowed | {'domain_keyword', 'package_name'}
    result = []
    removed = {}
    if source.get('version') not in (1, 2, 3) or set(source) != {'version', 'rules'}:
        raise ValueError('Unreviewed source format')
    if not isinstance(source['rules'], list) or not source['rules']:
        raise ValueError('Empty upstream rules')
    for rule in source['rules']:
        if not isinstance(rule, dict) or not rule:
            raise ValueError('Invalid upstream rule')
        if set(rule) - known:
            raise ValueError('Unreviewed upstream rule fields: ' + ', '.join(sorted(set(rule) - known)))
        # The upstream's domain fields form an OR group; process/package rules are
        # separate. Refuse mixed conditions instead of silently widening an AND.
        if 'process_name' in rule and len(rule) != 1:
            raise ValueError('Mixed process rule needs manual review')
        if 'package_name' in rule and len(rule) != 1:
            raise ValueError('Mixed package rule needs manual review')
        kept = {}
        for key, value in rule.items():
            values = value if isinstance(value, list) else [value]
            if not values or not all(isinstance(v, str) and v for v in values):
                raise ValueError('Invalid or empty upstream field: ' + key)
            if key in allowed:
                kept[key] = sorted(set(values))
            else:
                removed.setdefault(key, []).extend(values)
        if kept:
            result.append(kept)
    if not result or not any('domain_suffix' in r or 'domain' in r for r in result):
        raise ValueError('Empty domain subset')
    return {'version': 3, 'rules': result}, removed


def members(source):
    result = {}
    for rule in source['rules']:
        for field, values in rule.items():
            result.setdefault(field, set()).update(values if isinstance(values, list) else [values])
    return result


def guard_previous(candidate, previous):
    current, old = members(candidate), members(previous)
    for key, values in old.items():
        # This allow-list grows automatically. Removals require a reviewed policy
        # change rather than silently changing existing clients overnight.
        if not values <= current.get(key, set()):
            raise ValueError('Published entries removed: '+key)


def fetch():
    for attempt in range(3):
        try:
            with urllib.request.urlopen(URL, timeout=60) as response:
                return response.read()
        except OSError:
            if attempt == 2:
                raise
            time.sleep(2*(attempt+1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sing-box', required=True)
    parser.add_argument('--out-dir', type=Path, default=ROOT/'rules')
    parser.add_argument('--source-srs', type=Path, help='use an upstream binary snapshot')
    parser.add_argument('--upstream-output', type=Path, help='save the original binary for isolated tests')
    args = parser.parse_args()
    data = args.source_srs.read_bytes() if args.source_srs else fetch()
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory)/'upstream.srs'
        decoded = Path(directory)/'upstream.json'
        candidate = Path(directory)/'applications.json'
        source.write_bytes(data)
        subprocess.run([args.sing_box, 'rule-set', 'decompile', str(source), '-o', str(decoded)], check=True)
        result, removed = sanitize(json.loads(decoded.read_text('utf-8')))
        previous_path = args.out_dir/'applications-safe.json'
        if previous_path.exists():
            guard_previous(result, json.loads(previous_path.read_text('utf-8')))
        payload = json.dumps(result, ensure_ascii=False, indent=2)+'\n'
        candidate.write_text(payload, encoding='utf-8')
        subprocess.run([args.sing_box, 'rule-set', 'compile', str(candidate), '-o', str(candidate.with_suffix('.srs'))], check=True)
        binary = candidate.with_suffix('.srs').read_bytes()
    # CI commits only these validated outputs. No timestamps: unchanged inputs
    # remain byte-identical and produce no daily commit.
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir/'applications-safe.json').write_text(payload, encoding='utf-8', newline='\n')
    (args.out_dir/'applications-safe.srs').write_bytes(binary)
    manifest = {'url': URL, 'upstream_sha256': hashlib.sha256(data).hexdigest(),
                'source_sha256': hashlib.sha256(payload.encode()).hexdigest(),
                'srs_sha256': hashlib.sha256(binary).hexdigest(),
                'counts': {key: len(values) for key, values in members(result).items()},
                'upstream_license': 'https://github.com/DustinWin/ruleset_geodata/blob/main/LICENSE',
                'removed': removed, 'policy': 'Keep process names and exact/suffix domains; remove substring routing and macOS package names.'}
    (args.out_dir/'manifest-applications.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8', newline='\n')
    if args.upstream_output:
        args.upstream_output.parent.mkdir(parents=True, exist_ok=True)
        args.upstream_output.write_bytes(data)
    print('Built applications-safe:', manifest['counts'])


if __name__ == '__main__':
    main()
