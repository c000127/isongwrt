#!/usr/bin/env python3
"""Test conversion guardrails and compiled domain membership."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('builder', ROOT/'scripts/build-applications-rules.py')
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class ConversionTests(unittest.TestCase):
    def fixture(self):
        return {'version': 2, 'rules': [
            {'process_name': ['aria2c', 'qbittorrent']},
            {'domain_suffix': 'qbittorrent.org', 'domain_keyword': ['thunder', 'aria2']},
            {'package_name': ['io.tailscale.ipn.macos.network-extension']}]}

    def test_preserve_explicit_rules_without_broad_keywords(self):
        source = self.fixture()
        original = copy.deepcopy(source)
        result, removed = BUILD.sanitize(source)
        self.assertEqual(source, original)
        self.assertEqual(result['rules'], [{'process_name': ['aria2c', 'qbittorrent']},
                                           {'domain_suffix': ['qbittorrent.org']}])
        self.assertEqual(removed['domain_keyword'], ['thunder', 'aria2'])

    def test_unknown_or_mixed_semantics_are_rejected(self):
        for rule in ({'type': 'logical', 'rules': []}, {'domain_regex': ['.*']},
                     {'process_name': ['aria2c'], 'domain_suffix': ['example.com']},
                     {'package_name': ['example'], 'domain': ['example.com']}, {},
                     {'domain_suffix': []}, {'domain': [False]}):
            with self.subTest(rule=rule), self.assertRaises(ValueError):
                BUILD.sanitize({'version': 2, 'rules': [rule]})

    def test_empty_or_changed_source_format_is_rejected(self):
        for source in ({}, {'version': 99, 'rules': []}, {'version': 2, 'rules': []},
                       {'version': 2, 'rules': [], 'new_field': True}):
            with self.subTest(source=source), self.assertRaises(ValueError):
                BUILD.sanitize(source)

    def test_published_entries_cannot_silently_disappear(self):
        previous, _ = BUILD.sanitize(self.fixture())
        current = copy.deepcopy(previous)
        current['rules'][0]['process_name'].remove('aria2c')
        with self.assertRaises(ValueError):
            BUILD.guard_previous(current, previous)
        current['rules'][0]['process_name'].append('aria2c')
        current['rules'][0]['process_name'].append('transmission-daemon')
        BUILD.guard_previous(current, previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sing-box', required=True)
    parser.add_argument('--rules-dir', type=Path, default=ROOT/'rules')
    parser.add_argument('--upstream', type=Path, required=True)
    args = parser.parse_args()
    outcome = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ConversionTests))
    if not outcome.wasSuccessful():
        return 1
    manifest = json.loads((args.rules_dir/'manifest-applications.json').read_text('utf-8'))
    for filename, key in [('applications-safe.json', 'source_sha256'), ('applications-safe.srs', 'srs_sha256')]:
        assert hashlib.sha256((args.rules_dir/filename).read_bytes()).hexdigest() == manifest[key]
    assert hashlib.sha256(args.upstream.read_bytes()).hexdigest() == manifest['upstream_sha256']
    for path, safe in [(args.rules_dir/'applications-safe.srs', True), (args.upstream, False)]:
        for host in ('qbittorrent.org', 'www.qbittorrent.org', 'thunderbird.net',
                     'warthunder.com', 'aria2.github.io', 'thunder.example.com',
                     'notqbittorrent.org', 'qbittorrent.org.example.net'):
            result = subprocess.run([args.sing_box, '--disable-color', 'rule-set', 'match',
                                     '-f', 'binary', str(path), host],
                                    capture_output=True, text=True, encoding='utf-8', timeout=20)
            assert result.returncode == 0, result.stderr
            matched = 'match rules.' in result.stdout+result.stderr
            owned = host == 'qbittorrent.org' or host.endswith('.qbittorrent.org')
            # The upstream may eventually fix its own keyword rules. Do not
            # require the reference binary to keep reproducing a removed bug.
            expected = owned or (not safe and any(
                keyword in host for keyword in manifest['removed'].get('domain_keyword', [])))
            assert matched == expected, (path.name, host, matched, expected)
    print('PASS: artifact hashes and 16 compiled membership checks (including upstream controls)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
