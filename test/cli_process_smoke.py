"""Real executable transport/schema smoke test; needs Python jsonschema.

Pass an AOT executable path. This test clears PATH so init/validate cannot rely
on a discoverable Dart SDK or Node runtime. It is not platform certification.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
executable = str(Path(sys.argv[1]).resolve())
public = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
export = Draft202012Validator(json.loads((repository / 'contracts/json/export-diagnostics.schema.json').read_text()))
count = 0


def invoke(cwd, args, expected, export_mode=False):
    global count
    result = subprocess.run([executable, *args], cwd=cwd,
                            env={**os.environ, 'PATH': '/no-runtime-here'},
                            capture_output=True, timeout=10)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    content, other = (result.stderr, result.stdout) if export_mode else (result.stdout, result.stderr)
    assert other == b'', (args, other)
    assert content.endswith(b'\n') and content.count(b'\n') == 1 and not content.startswith(b'\xef\xbb\xbf')
    value = json.loads(content.decode('utf-8'))
    (export if export_mode else public).validate(value)
    assert value['exit_code'] == result.returncode
    count += 1
    return value


with tempfile.TemporaryDirectory(prefix='archway-process-') as temporary:
    base = Path(temporary).resolve()
    cwd = base / 'unrelated cwd ü'
    cwd.mkdir()
    policies = []
    for template in ['dart', 'typescript', 'mixed']:
        root = base / (template + ' root café')
        root.mkdir()
        preview = invoke(cwd, ['--root', str(root), 'init', '--template', template, '--dry-run'], 0)
        assert list(root.iterdir()) == []
        created = invoke(cwd, ['init', '--template=' + template, '--root=' + str(root)], 0)
        assert created['payload']['outcome'] == 'created'
        assert sorted(p.name for p in root.iterdir()) == ['ARCHITECTURE.md', 'architecture.yaml']
        for file in preview['payload']['planned_files']:
            assert (root / file['path']).read_bytes() == file['content'].encode('utf-8')
        validated = invoke(cwd, ['validate', '--root', str(root)], 0)
        policy = (root / 'architecture.yaml').read_bytes()
        assert validated['policy_hash'] == 'sha256:' + hashlib.sha256(policy).hexdigest()
        assert validated['payload'] == {'policy_valid': True, 'projects': 0, 'nodes': 0}
        assert [d['code'] for d in validated['diagnostics']] == ['EMPTY_PLAN']
        policies.append(b'\n'.join(line for line in policy.split(b'\n') if not line.startswith(b'#')))
        conflict = invoke(cwd, ['init', '--root', str(root), '--template', template, '--dry-run'], 2)
        assert conflict['payload']['outcome'] == 'conflict'
        assert len(conflict['payload']['planned_files']) == 2
    assert len(set(policies)) == 1
    invoke(cwd, ['validate'], 2)  # No parent/repository search from cwd.
    invoke(cwd, ['init', '--template', 'dart', '--policy', 'x'], 64)
    invoke(cwd, ['validate', '--policy', '../escape'], 64)
    invoke(cwd, ['not-a-command'], 64)
    invoke(cwd, ['export'], 64, export_mode=True)
    (cwd / 'architecture.yaml').write_text('[')
    invalid = invoke(cwd, ['validate'], 2)
    assert invalid['status'] == 'invalid_policy' and invalid['policy_hash'] is not None
    # Real permission denial, where available; root otherwise bypasses chmod.
    if sys.platform.startswith('linux'):
        base.chmod(0o755)
        cwd.chmod(0o755)
        denied = base / 'unreadable-root'
        denied.mkdir(mode=0o000)
        result = subprocess.run([executable, 'init', '--root', str(denied),
                                 '--template', 'dart', '--dry-run'], cwd=cwd,
                                capture_output=True, timeout=10,
                                env={**os.environ, 'PATH': '/no-runtime-here'},
                                preexec_fn=(lambda: os.setuid(65534)) if os.getuid() == 0 else None)
        assert result.returncode == 2, (result.stdout, result.stderr)
        value = json.loads(result.stdout)
        public.validate(value)
        assert value['status'] == 'error' and value['payload'] is None
        assert result.stderr == b''
        denied.chmod(0o700)
        count += 1
    for args in [['--help'], ['--version'], ['init', '--help']]:
        result = subprocess.run([executable, *args], cwd=cwd, capture_output=True, timeout=10, env={**os.environ, 'PATH': '/no-runtime-here'})
        assert result.returncode == 0 and result.stderr == b'' and result.stdout.startswith(b'archway')
        count += 1
print(f'{count} real executable transport/schema checks passed (runtime PATH cleared).')
