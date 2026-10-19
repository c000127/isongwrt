#!/usr/bin/env python3
"""Offline conversion and verification regressions using a real sing-box core."""
import argparse
from contextlib import redirect_stderr, redirect_stdout
import hashlib
from http.client import IncompleteRead
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT/'scripts'/file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


CONVERT = module('convert', 'convert-echs-lists.py')
VERIFY = module('verify', 'verify-echs-parity.py')
CORE = None


class EchsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='echs-tests-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.domain = self.root/'domain.list'
        self.ip = self.root/'ip.list'
        self.domain.write_text('+.suffix.example\nexact.example\n', encoding='utf-8')
        self.ip.write_text('192.0.2.0/24\n2001:db8::/32\n', encoding='utf-8')
        self.out = self.root/'release'

    def invoke(self, main, args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = main(list(map(str, args)))
        return code, stdout.getvalue(), stderr.getvalue()

    def convert(self, *args):
        return self.invoke(CONVERT.main, ['--out-dir', self.out, '--domain-file', self.domain,
                                         '--ip-file', self.ip, '--sing-box', CORE, *args])

    def snapshot(self):
        return {path.name: path.read_bytes() for path in self.out.iterdir()} if self.out.exists() else {}

    def compile(self, source, output):
        run = subprocess.run([str(CORE), 'rule-set', 'compile', str(source), '-o', str(output)],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)

    def native_domains(self, text, cases):
        data = CONVERT.parse_domains(text)
        self.assertEqual(data['domain_errors'], [])
        source = self.root/'native.json'
        source.write_text(json.dumps({'version': 3, 'rules': [
            {field: data[field]} for field in CONVERT.FIELDS[:3] if data[field]]}), encoding='utf-8')
        binary = self.root/'native.srs'
        self.compile(source, binary)
        for host, expected in cases.items():
            with self.subTest(host=host, text=text):
                self.assertEqual(VERIFY.tool_match(str(CORE), binary, host), expected)

    def release(self, name, domains=None, ips=None):
        directory = self.root/name
        directory.mkdir()
        for stem, rules in [('echsdirect', domains or [{'domain': ['exact.example']}]),
                            ('echsdirectip', [{'ip_cidr': ips or ['192.0.2.0/24']}])]:
            source = directory/(stem+'.json')
            source.write_text(json.dumps({'version': 3, 'rules': rules}), encoding='utf-8')
            self.compile(source, directory/(stem+'.srs'))
        return directory

    def verify(self, old, new, *args):
        return self.invoke(VERIFY.main, ['--old-dir', old, '--new-dir', new,
                                        '--sing-box', CORE, '--samples', 1, *args])

    def test_exact_suffix_and_subdomain_boundaries(self):
        self.native_domains('exact.example\n+.suffix.example\n.only.example', {
            'exact.example': True, 'sub.exact.example': False,
            'suffix.example': True, 'sub.suffix.example': True, 'deep.sub.suffix.example': True,
            'notsuffix.example': False, 'only.example': False, 'sub.only.example': True,
            'deep.sub.only.example': True, 'notonly.example': False})

    def test_star_matches_exactly_one_label(self):
        self.native_domains('*.example.com', {'example.com': False, 'a.example.com': True,
                                            'a.b.example.com': False, 'notexample.com': False})

    def test_internal_and_multiple_wildcards(self):
        self.native_domains('sub.*.example.com\n*.dev\nstun.*.*', {
            'sub.foo.example.com': True, 'foo.sub.example.com': False,
            'sub.foo.bar.example.com': False, 'a.dev': True, 'a.b.dev': False,
            'stun.one.two': True, 'stun.one.two.three': False})

    def test_wildcard_suffix_forms(self):
        self.native_domains('+.stun.*.*\n.apple.*', {
            'stun.one.two': True, 'global.stun.one.two': True,
            'deep.global.stun.one.two': True, 'stun.one': False,
            'apple.com': False, 'test.apple.com': True, 'deep.test.apple.com': True})

    def test_bare_star_is_single_label_not_dropped_or_global(self):
        self.native_domains('*', {'localhost': True, 'one': True, 'one.two': False})

    def test_hyphenated_wildcards_and_single_label_suffixes(self):
        self.native_domains('foo-bar.*\n+.cn', {'foo-bar.example': True, 'sub.foo-bar.example': False,
                                               'cn': True, 'site.cn': True, 'notcn': False})

    def test_comments_case_duplicates_and_line_counts(self):
        data = CONVERT.parse_domains('# comment\n// comment\n\n+.EXAMPLE.COM\n+.example.com\n')
        self.assertEqual(data['domain_suffix'], ['example.com'])
        self.assertEqual(data['domain_lines'], 2)
        self.assertEqual(data['domain_errors'], [])

    def test_unknown_domain_syntax_is_reported_with_line_number(self):
        for value in ('DOMAIN,example.com', '+', '*a.example', 'a..example', 'example.com.',
                      'a.+.example', 'https://example.com', '\u4f8b\u5b50.example', '+. example.com'):
            with self.subTest(value=value):
                result = CONVERT.parse_domains('# comment\n'+value)
                self.assertEqual(result['domain_errors'][0]['line'], 2)

    def test_strict_cidr_validation_and_normalization(self):
        parsed = CONVERT.parse_ips('192.0.2.9/24\n2001:0db8::1/32\n# comment\n// comment')
        self.assertEqual(parsed['ip_cidr'], ['192.0.2.0/24', '2001:db8::/32'])
        self.assertEqual(parsed['ip_errors'], [])
        for value in ('999.0.0.0/24', '192.0.2.0/33', '2001:db8::/129', '::g/64',
                      '192.0.2.1', 'fe80::%eth0/64', 'DOMAIN,example.com'):
            with self.subTest(value=value):
                self.assertEqual(len(CONVERT.parse_ips(value)['ip_errors']), 1)

    def test_domain_and_ip_errors_are_not_overwritten(self):
        self.domain.write_text('+.good.example\nBAD,domain\n', encoding='utf-8')
        self.ip.write_text('192.0.2.0/24\nBAD-ip\nBAD-ip-again\n', encoding='utf-8')
        code, output, errors = self.convert('--dry-run')
        self.assertEqual((code, output), (2, ''))
        self.assertIn('"domain":[{"line":2', errors)
        self.assertIn('"ip":[{"line":2', errors)
        self.assertIn('"line":3', errors)

    def test_unknown_lines_fail_before_core_or_writes(self):
        self.domain.write_text('+.good.example\nunknown-syntax,rest', encoding='utf-8')
        with patch.object(CONVERT, 'core', side_effect=AssertionError('must not compile')):
            code, output, _ = self.convert()
        self.assertEqual((code, output, self.snapshot()), (2, '', {}))

    def test_empty_inputs_fail(self):
        for file in (self.domain, self.ip):
            before = file.read_bytes()
            file.write_bytes(b'# empty\n')
            self.assertEqual(self.convert()[0], 2)
            file.write_bytes(before)
        self.assertFalse(self.out.exists())

    def test_same_count_domain_replacement_requires_review(self):
        self.assertEqual(self.convert()[0], 0)
        before = self.snapshot()
        self.domain.write_text('+.different.example\nexact.example', encoding='utf-8')
        self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.convert('--allow-domain-loss')[0], 0)

    def test_ip_shrink_threshold(self):
        new = {**CONVERT.parse_domains('+.example\nexact.example'),
               **CONVERT.parse_ips('\n'.join(f'192.0.2.{i}/32' for i in range(9)))}
        previous = {key: set(new[key]) for key in CONVERT.FIELDS}
        previous['ip_cidr'].add('192.0.2.9/32')
        self.assertEqual(CONVERT.guard(new, previous, 10, False)['ip_shrink_pct'], 10)
        with self.assertRaises(CONVERT.GuardError):
            CONVERT.guard(new, previous, 9.9, False)

    def test_nonfinite_or_invalid_threshold_fails(self):
        for value in ('nan', 'inf', '-1', '101'):
            with self.subTest(value=value):
                self.assertEqual(self.convert('--max-ip-shrink-pct', value)[0], 2)

    def test_compile_failure_keeps_all_previous_files(self):
        self.assertEqual(self.convert()[0], 0)
        before = self.snapshot()
        real_core = CONVERT.core
        def fail_second(binary, *args):
            if args[0] == 'rule-set' and str(args[2]).endswith('echsdirectip.json'):
                raise CONVERT.GuardError('injected compile failure')
            return real_core(binary, *args)
        with patch.object(CONVERT, 'core', side_effect=fail_second):
            self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.snapshot(), before)

    def test_missing_core_and_timeout_fail_closed(self):
        self.assertEqual(self.convert('--sing-box', self.root/'missing')[0], 2)
        with patch.object(CONVERT.subprocess, 'run', side_effect=subprocess.TimeoutExpired('core', 30)):
            self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.snapshot(), {})

    def test_empty_compiler_output_is_rejected(self):
        real_core = CONVERT.core
        def no_output(binary, *args):
            return real_core(binary, *args) if args[0] == 'version' else ''
        with patch.object(CONVERT, 'core', side_effect=no_output):
            self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.snapshot(), {})

    def test_debug_output_cannot_replace_a_release(self):
        self.assertEqual(self.convert()[0], 0)
        before = self.snapshot()
        self.assertEqual(self.convert('--skip-compile')[0], 2)
        self.assertEqual(self.snapshot(), before)
        empty = self.root/'debug'
        code, output, _ = self.convert('--out-dir', empty, '--skip-compile')
        self.assertEqual(code, 0)
        self.assertFalse(json.loads(output)['compiled'])
        self.assertFalse(list(empty.glob('*.srs')))

    def test_identical_runs_keep_every_byte_and_manifest(self):
        self.assertEqual(self.convert()[0], 0)
        before = self.snapshot()
        for _ in range(2):
            code, output, _ = self.convert()
            self.assertEqual(code, 0)
            self.assertTrue(json.loads(output)['unchanged'])
            self.assertEqual(self.snapshot(), before)

    def test_manifest_hashes_and_compiler_identity(self):
        self.domain.write_text('+.suffix.example\n*.one.example\n.only.example', encoding='utf-8')
        code, output, errors = self.convert()
        self.assertEqual((code, errors), (0, ''))
        manifest = json.loads(output)['manifest']
        self.assertEqual(manifest['counts']['domain_regex'], 1)
        self.assertEqual(manifest['unparsed_lines'], {'domain': 0, 'ip': 0})
        self.assertEqual(len(manifest['compiler_revision']), 40)
        for name, metadata in manifest['files'].items():
            data = (self.out/name).read_bytes()
            self.assertEqual(metadata, {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})

    def test_incorrect_manifest_counts_are_repaired(self):
        self.assertEqual(self.convert()[0], 0)
        path = self.out/'manifest-echs.json'
        manifest = json.loads(path.read_text('utf-8'))
        manifest['counts']['domain'] = 999
        path.write_text(json.dumps(manifest), encoding='utf-8')
        code, output, _ = self.convert()
        self.assertEqual(code, 0)
        summary = json.loads(output)
        self.assertFalse(summary['unchanged'])
        self.assertEqual(summary['manifest']['counts']['domain'], 1)

    def test_incomplete_and_corrupt_baselines_fail(self):
        self.out.mkdir()
        (self.out/'echsdirect.json').write_text('{}', encoding='utf-8')
        self.assertEqual(self.convert()[0], 2)
        (self.out/'echsdirectip.json').write_text('{}', encoding='utf-8')
        self.assertEqual(self.convert()[0], 2)

    def test_replace_failure_restores_files_and_removes_staging_files(self):
        self.assertEqual(self.convert()[0], 0)
        before = self.snapshot()
        real_replace = CONVERT.os.replace
        calls = 0
        def fail_second(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('injected write failure')
            return real_replace(source, target)
        with patch.object(CONVERT.os, 'replace', side_effect=fail_second):
            self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_utf8_read_and_truncated_download_fail(self):
        self.domain.write_bytes(b'\xff')
        self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.convert('--domain-file', self.root/'missing')[0], 2)
        with patch.object(CONVERT, 'read_input', side_effect=IncompleteRead(b'ab', 10)):
            self.assertEqual(self.convert()[0], 2)
        self.assertEqual(self.snapshot(), {})

    def test_verifier_checks_real_sources_and_native_boundaries(self):
        self.domain.write_text('exact.example\n+.suffix.example\n.only.example\n*.star.example', encoding='utf-8')
        self.assertEqual(self.convert()[0], 0)
        code, output, errors = self.verify(self.out, self.out, '--samples', 20)
        self.assertEqual((code, errors), (0, ''))
        report = json.loads(output)
        probes = {p['query']: p for p in report['probes'] if p['set'] == 'echsdirect'}
        self.assertFalse(probes['only.example']['old_match'])
        self.assertFalse(probes['deep.child.probe.star.example']['old_match'])
        self.assertTrue(report['ok'])
        self.assertIn('not whole-set equivalence', report['scope'])

    def test_verifier_accepts_expected_additions_and_removals(self):
        old = self.release('old', [{'domain_suffix': ['old.example', '.only.example']}])
        new = self.release('new', [{'domain_suffix': ['new.example', '.only.example']}], ['198.51.100.0/24'])
        code, output, _ = self.verify(old, new)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output)['counts']['domain_suffix']['removed'], 1)

    def test_verifier_rejects_missing_corrupt_and_stale_binaries(self):
        directory = self.release('release')
        srs = directory/'echsdirect.srs'
        original = srs.read_bytes()
        for data in (None, b'', b'broken SRS'):
            if data is None:
                srs.unlink()
            else:
                srs.write_bytes(data)
            self.assertEqual(self.verify(directory, directory)[0], 2)
        srs.write_bytes(original)
        (directory/'echsdirect.json').write_text(json.dumps({'version': 3, 'rules': [{'domain': ['different.example']}]}), encoding='utf-8')
        self.assertEqual(self.verify(directory, directory)[0], 2)

    def test_verifier_rejects_unknown_rules_and_regex_grammar(self):
        directory = self.release('release')
        for rule in ({'domain': ['exact.example'], 'invert': False}, {'domain_regex': ['.*']},
                     {'domain_keyword': ['example']}, {'type': 'logical', 'rules': []}):
            (directory/'echsdirect.json').write_text(json.dumps({'version': 3, 'rules': [rule]}), encoding='utf-8')
            self.assertEqual(self.verify(directory, directory)[0], 2)

    def test_verifier_core_errors_and_diagnostics_are_not_misses(self):
        results = [subprocess.CompletedProcess([], 7, '', 'FATAL'),
                   subprocess.CompletedProcess([], 9, 'match rules.[0]: fake', ''),
                   subprocess.CompletedProcess([], 0, '', 'unexpected diagnostic'),
                   subprocess.CompletedProcess([], 0, 'match rules.[0]: fake\nWARNING', '')]
        for result in results:
            with self.subTest(result=result), patch.object(VERIFY.subprocess, 'run', return_value=result):
                with self.assertRaises(VERIFY.VerificationError):
                    VERIFY.tool_match(str(CORE), self.root/'set.srs', 'sample.example')
        with patch.object(VERIFY.subprocess, 'run', side_effect=subprocess.TimeoutExpired('core', 30)):
            with self.assertRaises(VERIFY.VerificationError):
                VERIFY.tool_match(str(CORE), self.root/'set.srs', 'sample.example')

    def test_verifier_accepts_match_on_either_output_stream(self):
        for stdout, stderr in [('match rules.[0]: domain=test', ''), ('', 'match rules.[0]: domain=test'), ('', '')]:
            with patch.object(VERIFY.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout, stderr)):
                self.assertEqual(VERIFY.tool_match(str(CORE), self.root/'set.srs', 'test'), bool(stdout+stderr))

    def test_verifier_reports_mismatch_as_exit_one(self):
        directory = self.release('release')
        with patch.object(VERIFY, 'tool_match', return_value=False):
            code, output, _ = self.verify(directory, directory)
        self.assertEqual(code, 1)
        self.assertFalse(json.loads(output)['ok'])

    def test_verifier_overwrites_stale_success_report_on_errors(self):
        report = self.root/'report.json'
        report.write_text('{"ok":true}', encoding='utf-8')
        code, output, _ = self.verify(self.root/'missing', self.root/'missing', '--report', report)
        self.assertEqual(code, 2)
        self.assertFalse(json.loads(output)['ok'])
        self.assertFalse(json.loads(report.read_text('utf-8'))['ok'])

    def test_verifier_rejects_zero_negative_or_unbounded_samples(self):
        for number in (0, -1, 1001):
            self.assertEqual(self.verify(self.root, self.root, '--samples', number)[0], 2)


def main():
    global CORE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sing-box', type=Path, required=True)
    args = parser.parse_args()
    CORE = args.sing_box.resolve()
    if not CORE.is_file():
        parser.error('sing-box binary does not exist')
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(EchsTests))
    return int(not result.wasSuccessful())


if __name__ == '__main__':
    raise SystemExit(main())
