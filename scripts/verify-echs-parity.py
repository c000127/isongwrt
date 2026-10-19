#!/usr/bin/env python3
"""Verify source/binary consistency and sampled membership of two ECH releases.

Exit 0: sampled matches agree with each release's model; 1: mismatch; 2: error.
Expected additions/removals are reported, not treated as whole-set equivalence.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SEED = 20260926
DOMAIN_FIELDS = ('domain_suffix', 'domain', 'domain_regex')
LABEL = re.compile(r'[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?')


class VerificationError(ValueError):
    pass


def regex_examples(pattern: str) -> list[str]:
    # Only the converter's small RE2/Python-compatible grammar is modelled.
    if not pattern.startswith('^') or not pattern.endswith('$'):
        raise VerificationError('unsupported regex grammar')
    body = pattern[1:-1]
    for prefix in (r'([^.]+\.)*', r'([^.]+\.)+'):
        if body.startswith(prefix):
            body = body[len(prefix):]
            break
    parts = body.split(r'\.')
    if not parts or any(part != '[^.]+' and not LABEL.fullmatch(part) for part in parts):
        raise VerificationError('unsupported regex grammar')
    host = '.'.join('probe' if part == '[^.]+' else part for part in parts)
    return [host, 'child.'+host, 'deep.child.'+host, 'not'+host, host+'.invalid']


def load_source(path: Path, allowed: set[str]) -> dict:
    doc = json.loads(path.read_text('utf-8'))
    if (not isinstance(doc, dict) or set(doc) != {'version', 'rules'} or
            doc['version'] not in (1, 2, 3) or not isinstance(doc['rules'], list) or not doc['rules']):
        raise VerificationError('unsupported rule-set structure')
    result = {field: set() for field in allowed}
    for rule in doc['rules']:
        if (not isinstance(rule, dict) or not rule or set(rule)-(allowed | {'type'}) or
                rule.get('type', 'default') != 'default' or not (set(rule) & allowed)):
            raise VerificationError('unsupported rule-set semantics')
        for field in allowed & set(rule):
            values = rule[field] if isinstance(rule[field], list) else [rule[field]]
            if not values or not all(isinstance(value, str) and value for value in values):
                raise VerificationError('invalid rule-set values')
            for value in values:
                if field == 'ip_cidr':
                    value = str(ipaddress.ip_network(value, strict=False))
                elif field == 'domain_regex':
                    regex_examples(value)
                    re.compile(value)
                else:
                    bare = value[1:] if field == 'domain_suffix' and value.startswith('.') else value
                    if not bare or any(not LABEL.fullmatch(label) for label in bare.split('.')):
                        raise VerificationError('unsupported domain entry')
                result[field].add(value)
    return result


def core(binary: str, *args) -> str:
    try:
        result = subprocess.run([binary, '--disable-color', 'rule-set', *map(str, args)],
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise VerificationError('sing-box unavailable or timed out') from None
    if result.returncode:
        raise VerificationError(f'sing-box {args[0]} failed (exit {result.returncode})')
    return (result.stdout+result.stderr).strip()


def tool_match(binary: str, srs: Path, query: str) -> bool:
    output = core(binary, 'match', '-f', 'binary', srs, query)
    if output and not all(re.fullmatch(r'match rules\.\[\d+\]: .+', line) for line in output.splitlines()):
        raise VerificationError('unrecognized sing-box match output')
    return bool(output)


def load_sets(directory: Path, binary: str, temporary: Path, prefix: str) -> dict:
    result = {}
    for stem, allowed in (('echsdirect', set(DOMAIN_FIELDS)), ('echsdirectip', {'ip_cidr'})):
        source, srs = directory/(stem+'.json'), directory/(stem+'.srs')
        if not source.is_file() or not srs.is_file():
            raise VerificationError('incomplete release: JSON and SRS are both required')
        expected = load_source(source, allowed)
        decompiled = temporary/(prefix+'-'+stem+'.json')
        core(binary, 'decompile', srs, '-o', decompiled)
        if load_source(decompiled, allowed) != expected:
            raise VerificationError('source/binary content mismatch: '+stem)
        result.update(expected)
    result['_networks'] = [ipaddress.ip_network(value) for value in result['ip_cidr']]
    return result


def dom_model(data: dict, host: str) -> bool:
    host = host.lower()
    if host in data['domain']:
        return True
    for suffix in data['domain_suffix']:
        matches = host.endswith(suffix) if suffix.startswith('.') else host == suffix or host.endswith('.'+suffix)
        if matches:
            return True
    return any(re.search(pattern, host) for pattern in data['domain_regex'])


def ip_model(data: dict, host: str) -> bool:
    address = ipaddress.ip_address(host)
    return any(address.version == network.version and address in network for network in data['_networks'])


def domain_examples(field: str, value: str) -> list[str]:
    if field == 'domain_regex':
        return regex_examples(value)
    host = value.lstrip('.')
    return [host, 'child.'+host, 'deep.child.'+host, 'not'+host, host+'.invalid']


def ip_examples(value: str) -> list[str]:
    network = ipaddress.ip_network(value)
    addresses = {network.network_address, network.broadcast_address}
    if network.num_addresses > 2:
        addresses.add(network.network_address+1)
    if int(network.network_address):
        addresses.add(network.network_address-1)
    if int(network.broadcast_address) < (1 << network.max_prefixlen)-1:
        addresses.add(network.broadcast_address+1)
    return [str(address) for address in sorted(addresses)]


def verify(args) -> dict:
    if not 1 <= args.samples <= 1000:
        raise VerificationError('--samples must be between 1 and 1000')
    old_dir, new_dir = Path(args.old_dir), Path(args.new_dir)
    with tempfile.TemporaryDirectory(prefix='echs-parity-') as temporary:
        old = load_sets(old_dir, args.sing_box, Path(temporary), 'old')
        new = load_sets(new_dir, args.sing_box, Path(temporary), 'new')
    report = {'ok': True, 'scope': 'source/binary consistency and sampled membership; not whole-set equivalence',
              'seed': SEED, 'samples_per_field_and_change': args.samples, 'counts': {}, 'probes': [], 'failed': []}
    randomizer = random.Random(SEED)
    probes = {}
    for field in (*DOMAIN_FIELDS, 'ip_cidr'):
        before, after = old[field], new[field]
        report['counts'][field] = {'old': len(before), 'new': len(after),
                                  'added': len(after-before), 'removed': len(before-after)}
        for kind, pool in (('common', before & after), ('added', after-before), ('removed', before-after)):
            items = sorted(pool)
            randomizer.shuffle(items)
            for value in items[:args.samples]:
                queries = ip_examples(value) if field == 'ip_cidr' else domain_examples(field, value)
                for query in queries:
                    stem = 'echsdirectip' if field == 'ip_cidr' else 'echsdirect'
                    probes.setdefault((stem, query), (kind, field))
    for query in ('zz-parity-neg.notarealtld-xyz', 'deep.zz-parity-neg.notarealtld-xyz'):
        probes.setdefault(('echsdirect', query), ('control', 'domain'))
    for query in ('203.0.113.254', '2001:db8::dead:beef'):
        probes.setdefault(('echsdirectip', query), ('control', 'ip_cidr'))
    for (stem, query), (kind, field) in probes.items():
        model = ip_model if stem == 'echsdirectip' else dom_model
        expected_old, expected_new = bool(model(old, query)), bool(model(new, query))
        actual_old = tool_match(args.sing_box, old_dir/(stem+'.srs'), query)
        actual_new = tool_match(args.sing_box, new_dir/(stem+'.srs'), query)
        ok = actual_old == expected_old and actual_new == expected_new
        record = {'set': stem, 'field': field, 'kind': kind, 'query': query,
                  'old_match': actual_old, 'new_match': actual_new,
                  'old_model': expected_old, 'new_model': expected_new, 'ok': ok}
        report['probes'].append(record)
        if not ok:
            report['failed'].append(stem+': '+query)
    report['ok'] = not report['failed']
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--old-dir', required=True)
    parser.add_argument('--new-dir', required=True)
    parser.add_argument('--sing-box', default='sing-box')
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--report')
    args = parser.parse_args(argv)
    try:
        report = verify(args)
        code = 0 if report['ok'] else 1
    except (VerificationError, OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        detail = str(error) if isinstance(error, VerificationError) else type(error).__name__
        report, code = {'ok': False, 'error': detail}, 2
    text = json.dumps(report, indent=1, ensure_ascii=False)+'\n'
    if args.report:
        try:
            Path(args.report).write_text(text, encoding='utf-8')
        except OSError:
            print('Cannot write verification report', file=sys.stderr)
            return 2
    print(text, end='')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
