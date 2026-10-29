#!/usr/bin/env python3
"""Regression checks for the domain-only publisher."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = Path(os.environ['DOMAIN_FILE']).read_text(encoding='utf-8')
script = root / 'scripts/update-echs-domain.py'
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    (work / 'rules').mkdir()
    for name in ('echsdirect.json', 'echsdirect.srs'):
        shutil.copy(root / 'rules' / name, work / 'rules' / name)
    input_file = work / 'domain.list'
    env = dict(os.environ, DOMAIN_FILE=str(input_file))
    def run(text):
        input_file.write_text(text, encoding='utf-8')
        return subprocess.run([sys.executable, str(script)], cwd=work, env=env, capture_output=True)
    assert run(source).returncode == 0, 'valid upstream rejected'
    outputs = {p.name: p.read_bytes() for p in (work / 'rules').iterdir()}
    assert run(source).returncode == 0, 'repeat rejected'
    assert outputs == {p.name: p.read_bytes() for p in (work / 'rules').iterdir()}, 'not reproducible'
    baseline = json.loads((work / 'rules/echsdirect.json').read_text(encoding='utf-8'))
    baseline['rules'].append({'domain': ['codex-removal-guard.example']})
    (work / 'rules/echsdirect.json').write_text(json.dumps(baseline), encoding='utf-8')
    assert run(source).returncode != 0, 'removed domain accepted'
    assert run(source + '\nnot a valid domain!\n').returncode != 0, 'invalid domain accepted'
    assert not (work / 'rules/echsdirectip.srs').exists(), 'IP artifact generated'
print('Domain-only regressions passed')
