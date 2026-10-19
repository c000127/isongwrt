#!/usr/bin/env python3
"""Convert public echs-top domain/CIDR lists; validate before replacing outputs."""
from __future__ import annotations

import argparse
import hashlib
from http.client import HTTPException
import ipaddress
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

SOURCE_DOMAIN = 'https://raw.githubusercontent.com/echs-top/proxy/main/list/domain/direct.list'
SOURCE_IP = 'https://raw.githubusercontent.com/echs-top/proxy/main/list/ip/direct.list'
UA = 'isongwrt-rules-echs/2.0'
FIELDS = ('domain_suffix', 'domain', 'domain_regex', 'ip_cidr')
LABEL = re.compile(r'[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?')


class GuardError(ValueError):
    pass


def read_input(url: str, path: str | None) -> tuple[str, str, str]:
    if path:
        data = Path(path).read_bytes()
    else:
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=60) as response:
            data = response.read()
    return data.decode('utf-8-sig'), f'file:{path}' if path else url, hashlib.sha256(data).hexdigest()


def entries(text: str):
    for number, raw in enumerate(text.splitlines(), 1):
        value = raw.strip()
        if value and not value.startswith(('#', '//')):
            yield number, value


def domain_pattern(value: str) -> tuple[str, str]:
    """Mihomo: +. includes the base, . excludes it, * consumes one label."""
    value = value.lower()
    mode = 'exact'
    if value.startswith('+.'):
        mode, value = 'suffix', value[2:]
    elif value.startswith('.'):
        mode, value = 'subdomain', value[1:]
    labels = value.split('.')
    if (not value or len(value) > 253 or
            any(label != '*' and not LABEL.fullmatch(label) for label in labels)):
        raise GuardError('unsupported domain pattern')
    if '*' not in labels:
        return ('domain', value) if mode == 'exact' else ('domain_suffix', ('.' if mode == 'subdomain' else '')+value)
    body = r'\.'.join('[^.]+' if label == '*' else label for label in labels)
    prefix = {'exact': '^', 'suffix': r'^([^.]+\.)*', 'subdomain': r'^([^.]+\.)+'}[mode]
    return 'domain_regex', prefix+body+'$'


def parse_domains(text: str) -> dict:
    result = {field: [] for field in FIELDS[:3]}
    errors = []
    accepted = 0
    for number, value in entries(text):
        try:
            field, pattern = domain_pattern(value)
            result[field].append(pattern)
            accepted += 1
        except GuardError:
            errors.append({'line': number, 'reason': 'unsupported domain pattern'})
    return {**{key: sorted(set(values)) for key, values in result.items()},
            'domain_errors': errors, 'domain_lines': accepted+len(errors)}


def parse_ips(text: str) -> dict:
    result, errors = [], []
    for number, value in entries(text):
        try:
            if '/' not in value or '%' in value:
                raise ValueError('CIDR required')
            result.append(str(ipaddress.ip_network(value, strict=False)))
        except ValueError:
            errors.append({'line': number, 'reason': 'invalid CIDR'})
    return {'ip_cidr': sorted(set(result)), 'ip_errors': errors,
            'ip_lines': sum(1 for _ in entries(text))}


def load_previous(directory: Path) -> dict | None:
    paths = [directory/'echsdirect.json', directory/'echsdirectip.json']
    if not any(path.exists() for path in paths):
        if any(directory.glob('echs*.srs')) or (directory/'manifest-echs.json').exists():
            raise GuardError('incomplete baseline')
        return None
    if not all(path.is_file() for path in paths):
        raise GuardError('incomplete baseline')
    result = {field: set() for field in FIELDS}
    for path, allowed in zip(paths, (set(FIELDS[:3]), {'ip_cidr'})):
        doc = json.loads(path.read_text('utf-8'))
        if set(doc) != {'version', 'rules'} or doc['version'] not in (1, 2, 3) or not isinstance(doc['rules'], list):
            raise GuardError('unsupported baseline structure')
        for rule in doc['rules']:
            if not isinstance(rule, dict) or not rule or set(rule)-allowed:
                raise GuardError('unsupported baseline rule')
            for field, values in rule.items():
                if not isinstance(values, list) or not values or not all(isinstance(v, str) and v for v in values):
                    raise GuardError('invalid baseline entries')
                result[field].update(values)
    if not any(result[field] for field in FIELDS[:3]) or not result['ip_cidr']:
        raise GuardError('empty baseline')
    return result


def counts(data: dict) -> dict:
    return {field: len(data[field]) for field in FIELDS}


def guard(new: dict, previous: dict | None, threshold: float, allow_domain_loss: bool) -> dict:
    if not math.isfinite(threshold) or not 0 <= threshold <= 100:
        raise GuardError('IP shrink threshold must be finite and between 0 and 100')
    errors = {'domain': new['domain_errors'], 'ip': new['ip_errors']}
    if any(errors.values()):
        raise GuardError('unparsed lines: '+json.dumps(errors, separators=(',', ':')))
    if not any(new[field] for field in FIELDS[:3]) or not new['ip_cidr']:
        raise GuardError('empty domain or IP set')
    delta = {field: None for field in FIELDS}
    if previous is not None:
        delta = {field: len(new[field])-len(previous[field]) for field in FIELDS}
        if not allow_domain_loss:
            for field in FIELDS[:3]:
                if previous[field]-set(new[field]):
                    raise GuardError('published '+field+' entries removed; review before --allow-domain-loss')
        old_ip = len(previous['ip_cidr'])
        shrink = 100*(old_ip-len(new['ip_cidr']))/old_ip if old_ip else 0
        if shrink > threshold:
            raise GuardError(f'IP set shrank {shrink:.2f}% (limit {threshold}%)')
        if shrink > 0:
            delta['ip_shrink_pct'] = round(shrink, 3)
    return delta


def build_sources(new: dict) -> dict:
    return {'echsdirect': {'version': 3, 'rules': [{field: new[field]} for field in FIELDS[:3] if new[field]]},
            'echsdirectip': {'version': 3, 'rules': [{'ip_cidr': new['ip_cidr']}]}}


def core(binary: str, *args) -> str:
    try:
        result = subprocess.run([binary, '--disable-color', *map(str, args)], capture_output=True,
                                text=True, encoding='utf-8', timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise GuardError('compiler unavailable or timed out') from None
    if result.returncode:
        raise GuardError(f'compiler {args[0]} failed (exit {result.returncode})')
    return result.stdout+result.stderr


def publish(directory: Path, produced: dict[str, bytes]):
    """Prepare all files first; restore replaced files on ordinary write errors."""
    directory.mkdir(parents=True, exist_ok=True)
    previous, staged, replaced = {}, {}, []
    try:
        for name, data in produced.items():
            target = directory/name
            previous[name] = target.read_bytes() if target.exists() else None
            staged[name] = directory/(name+'.new')
            staged[name].write_bytes(data)
        for name, path in staged.items():
            os.replace(path, directory/name)
            replaced.append(name)
    except OSError:
        for name in replaced:
            target = directory/name
            if previous[name] is None:
                target.unlink(missing_ok=True)
            else:
                target.write_bytes(previous[name])
        raise
    finally:
        for path in staged.values():
            path.unlink(missing_ok=True)


def run(args) -> dict:
    out = Path(args.out_dir)
    baseline = Path(args.baseline_dir) if args.baseline_dir else out
    domain, domain_origin, domain_hash = read_input(SOURCE_DOMAIN, args.domain_file)
    ips, ip_origin, ip_hash = read_input(SOURCE_IP, args.ip_file)
    new = {**parse_domains(domain), **parse_ips(ips)}
    previous = load_previous(baseline)
    delta = guard(new, previous, args.max_ip_shrink_pct, args.allow_domain_loss)
    summary = {'ok': True, 'counts': counts(new), 'previous': counts(previous) if previous is not None else None,
               'delta': delta, 'skipped': {'domain': len(new['domain_errors']), 'ip': len(new['ip_errors'])},
               'parsed_lines': {'domain': new['domain_lines'], 'ip': new['ip_lines']},
               'sources': {'domain': domain_origin, 'ip': ip_origin}}
    if args.dry_run:
        return {**summary, 'dry_run': True, 'compiled': False}
    if args.skip_compile and out.exists() and any(out.iterdir()):
        raise GuardError('--skip-compile requires an empty output directory; debug JSON must not replace published binaries')
    sources = build_sources(new)
    inputs_hash = hashlib.sha256(json.dumps(sources, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    old_manifest_path = baseline/'manifest-echs.json'
    old_manifest_bytes = old_manifest_path.read_bytes() if old_manifest_path.exists() else None
    old_manifest = json.loads(old_manifest_bytes) if old_manifest_bytes else {}
    with tempfile.TemporaryDirectory(prefix='echs-build-') as temporary:
        work = Path(temporary)
        produced = {}
        version, revision = 'not compiled', None
        if not args.skip_compile:
            info = core(args.sing_box, 'version')
            version_match = re.search(r'^sing-box version (\S+)$', info, re.M)
            revision_match = re.search(r'^Revision: ([a-f0-9]{40})$', info, re.M)
            if not version_match or not revision_match:
                raise GuardError('unrecognized compiler identity')
            version, revision = version_match[1], revision_match[1]
        for name, source in sources.items():
            path = work/(name+'.json')
            path.write_bytes((json.dumps(source, indent=1, ensure_ascii=False)+'\n').encode())
            produced[path.name] = path.read_bytes()
            if not args.skip_compile:
                binary = work/(name+'.srs')
                core(args.sing_box, 'rule-set', 'compile', path, '--output', binary)
                if not binary.is_file() or not binary.stat().st_size:
                    raise GuardError('compiler did not produce a nonempty binary')
                produced[binary.name] = binary.read_bytes()
        files = {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
                 for name, data in sorted(produced.items())}
        source_hashes = {'domain': domain_hash, 'ip': ip_hash}
        unchanged = (old_manifest.get('conversion_version') == 2 and
                     old_manifest.get('files') == files and old_manifest.get('inputs_sha256') == inputs_hash and
                     old_manifest.get('source_sha256') == source_hashes and
                     old_manifest.get('counts') == summary['counts'] and
                     old_manifest.get('unparsed_lines') == summary['skipped'] and
                     old_manifest.get('parsed_lines') == summary['parsed_lines'] and
                     old_manifest.get('source_url') == {'echsdirect': SOURCE_DOMAIN, 'echsdirectip': SOURCE_IP} and
                     old_manifest.get('compiler') == version and old_manifest.get('compiler_revision') == revision)
        if unchanged:
            manifest_bytes = old_manifest_bytes
            manifest = old_manifest
        else:
            manifest = {'conversion_version': 2,
                        'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(int(os.environ.get('SOURCE_DATE_EPOCH', time.time())))),
                        'inputs_sha256': inputs_hash, 'generator': 'scripts/convert-echs-lists.py',
                        'source_url': {'echsdirect': SOURCE_DOMAIN, 'echsdirectip': SOURCE_IP},
                        'source_sha256': source_hashes, 'compiler': version, 'compiler_revision': revision,
                        'counts': summary['counts'], 'previous': summary['previous'], 'delta': delta,
                        'unparsed_lines': summary['skipped'], 'parsed_lines': summary['parsed_lines'], 'files': files}
            manifest_bytes = (json.dumps(manifest, indent=1, ensure_ascii=False)+'\n').encode()
        produced['manifest-echs.json'] = manifest_bytes
        publish(out, produced)
    return {**summary, 'compiled': not args.skip_compile, 'unchanged': unchanged,
            'written': sorted(produced), 'manifest': manifest}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', default='rules')
    parser.add_argument('--baseline-dir')
    parser.add_argument('--sing-box', default=os.environ.get('SING_BOX_BIN', 'sing-box'))
    parser.add_argument('--domain-file')
    parser.add_argument('--ip-file')
    parser.add_argument('--skip-compile', action='store_true', help='Debug JSON only; requires an empty output directory')
    parser.add_argument('--allow-domain-loss', action='store_true')
    parser.add_argument('--max-ip-shrink-pct', type=float, default=10.0)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    try:
        print(json.dumps(run(args), indent=1, ensure_ascii=False))
        return 0
    except (GuardError, OSError, ValueError, TypeError, AttributeError, KeyError, HTTPException) as error:
        detail = str(error) if isinstance(error, GuardError) else type(error).__name__
        print('Conversion failed: '+detail, file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
