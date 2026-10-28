#!/usr/bin/env python3
"""Limit the one-time approval to the reviewed upstream removal."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('converter', Path(__file__).with_name('convert-echs-lists.py'))
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)

def main(baseline, source):
    previous = converter.load_previous(Path(baseline))
    if previous is None:
        raise converter.GuardError('approved removal requires a complete baseline')
    text = Path(source).read_text(encoding='utf-8-sig')
    new = converter.parse_domains(text)
    if new['domain_errors']:
        raise converter.GuardError('upstream contains unparsed domain entries')
    removed = {field: previous[field] - set(new[field]) for field in converter.FIELDS[:3]}
    expected = {'domain_suffix': {'moegirl.org'}, 'domain': set(), 'domain_regex': set()}
    if removed != expected:
        raise converter.GuardError('domain removals differ from the approved moegirl.org removal')
    print('Approved removal: domain_suffix moegirl.org')

if __name__ == '__main__':
    try:
        if len(sys.argv) != 3:
            raise converter.GuardError('expected baseline directory and domain source')
        main(*sys.argv[1:])
    except (converter.GuardError, OSError, ValueError) as error:
        print(f'Approval check failed: {error}', file=sys.stderr)
        sys.exit(2)
