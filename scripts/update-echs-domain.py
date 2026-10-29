#!/usr/bin/env python3
"""Update only the echs domain set, rejecting unreviewed domain removals."""
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile
from pathlib import Path

base = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('converter', base / 'convert-echs-lists.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
fields = c.FIELDS[:3]
target = Path('rules')
source, _, source_hash = c.read_input(c.SOURCE_DOMAIN, os.environ['DOMAIN_FILE'])
new = c.parse_domains(source)
if new['domain_errors'] or not any(new[f] for f in fields):
    raise SystemExit('Invalid or empty upstream domain list')
old = json.loads((target / 'echsdirect.json').read_text(encoding='utf-8'))
previous = {f: set() for f in fields}
if old.get('version') not in (1, 2, 3) or not isinstance(old.get('rules'), list):
    raise SystemExit('Invalid domain baseline')
for rule in old['rules']:
    if not isinstance(rule, dict) or not rule or set(rule) - set(fields):
        raise SystemExit('Invalid baseline rule')
    for field, values in rule.items():
        if not isinstance(values, list) or not values or not all(isinstance(v, str) and v for v in values):
            raise SystemExit('Invalid baseline values')
        previous[field].update(values)
if not any(previous.values()):
    raise SystemExit('Empty baseline')
for f in fields:
    if previous[f] - set(new[f]):
        raise SystemExit(f'Published {f} entries removed; review required')
doc = {'version': 3, 'rules': [{f: new[f]} for f in fields if new[f]]}
with tempfile.TemporaryDirectory() as t:
    src, compiled, decoded = (Path(t) / x for x in ('source.json', 'compiled.srs', 'decoded.json'))
    src.write_text(json.dumps(doc, indent=1, ensure_ascii=False)+'\n', encoding='utf-8')
    core = os.environ['SING_BOX_BIN']
    subprocess.run([core, 'rule-set', 'compile', str(src), '-o', str(compiled)], check=True)
    subprocess.run([core, 'rule-set', 'decompile', str(compiled), '-o', str(decoded)], check=True)
    actual = {f: set() for f in fields}
    for rule in json.loads(decoded.read_text(encoding='utf-8'))['rules']:
        for f in fields:
            actual[f].update(rule.get(f, []))
    if any(actual[f] != set(new[f]) for f in fields):
        raise SystemExit('Compiled rule set does not match source')
    files = {'echsdirect.json': src.read_bytes(), 'echsdirect.srs': compiled.read_bytes()}
    manifest = {'source_url': c.SOURCE_DOMAIN, 'source_sha256': source_hash,
                'counts': {f: len(new[f]) for f in fields},
                'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
    files['manifest-echs-domain.json'] = (json.dumps(manifest, indent=1, sort_keys=True)+'\n').encode()
    c.publish(target, files)
print('Domain rules validated and compiled; IP rules not fetched or changed.')
