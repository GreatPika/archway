"""Supplementary real AOT/schema checks against the versioned policy oracle.

This exercises CLI.run through its actual process with no discoverable runtime.
It supplements owning-seam tests, and does not certify another host platform.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

repo = Path(__file__).resolve().parents[1]
contracts = repo / 'contracts/json'
executable = str(Path(sys.argv[1]).resolve())
validator = Draft202012Validator(json.loads((contracts / 'public-result.schema.json').read_text()))
spec = importlib.util.spec_from_file_location('entrypoint_oracle', contracts / 'entrypoint_oracle.py')
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)
index = json.loads((contracts / 'fixture-index.json').read_text())
count = 0

with tempfile.TemporaryDirectory(prefix='archway-plan-query-') as temp:
    root = Path(temp) / 'root café'
    root.mkdir()
    cwd = Path(temp) / 'other cwd'
    cwd.mkdir()
    policy_file = root / 'architecture.yaml'

    def invoke(args, exit_code):
        global count
        process = subprocess.run([executable, '--root', str(root), *args], cwd=cwd,
                                 env={**os.environ, 'PATH': '/no-runtime-here'},
                                 capture_output=True, timeout=10)
        assert process.returncode == exit_code, (args, process.stdout, process.stderr)
        assert process.stderr == b''
        assert process.stdout.count(b'\n') == 1 and process.stdout.endswith(b'\n')
        value = json.loads(process.stdout)
        validator.validate(value)
        assert value['exit_code'] == process.returncode
        count += 1
        return value

    for entry in index:
        if entry['schema'] != 'policy':
            continue
        policy_file.write_bytes((contracts / entry['file']).read_bytes())
        result = invoke(['validate'], 0 if entry['valid'] else 2)
        assert result['status'] == ('ok' if entry['valid'] else 'invalid_policy'), entry
        assert result['policy_hash'] == 'sha256:' + hashlib.sha256(policy_file.read_bytes()).hexdigest()
        if entry['valid']:
            policy = json.loads(policy_file.read_text())
            assert result['payload'] == {'policy_valid': True, 'projects': len(policy['projects']), 'nodes': len(policy['nodes'])}
        else:
            assert result['payload'] is None and result['diagnostics']

    for entry in index:
        if not entry.get('policy') or not entry['valid']:
            continue
        expected = json.loads((contracts / entry['file']).read_text())
        if expected['command'] != 'allows':
            continue
        policy_file.write_bytes((contracts / entry['policy']).read_bytes())
        payload = expected['payload']
        args = ['allows', payload['from_id'], payload['to_id']] if payload['mode'] == 'ids' else ['allows', '--paths', payload['from']['path'], payload['to']['path']]
        result = invoke(args, expected['exit_code'])
        assert result['payload'] == payload, entry
        oracle.verify_linked(result, json.loads(policy_file.read_text()))

    policy_file.write_bytes((contracts / 'fixtures/policy-entrypoints.json').read_bytes())
    for args in [
        ['owner', 'src/app/planned.ts'], ['owner', 'outside/file'],
        ['node', 'app'], ['node', '--path', 'src/app/planned.ts'], ['node', '--path', 'outside/file'],
        ['node', 'missing'], ['allows', 'app', 'missing'],
    ]:
        expected_exit = 2 if 'missing' in args else 1 if 'outside/file' in args else 0
        invoke(args, expected_exit)
    for args in [
        ['owner'], ['owner', '../escape'], ['owner', 'C:relative'], ['owner', 'src/[x]'],
        ['node', 'app', '--path', 'src/app/a'], ['node', '--path'], ['node', 'app', '--limit', '1'],
        ['allows', '--paths', 'src/app/', 'src/app/a'], ['allows', '--paths', '.', 'src/app/a'],
        ['allows', '--paths', 'src/app/a', 'src/app/x/..'], ['allows', '--paths=foo', 'x', 'y'],
        ['allows', 'app'], ['allows', 'app', 'pricing', 'extra'], ['owner', '--json', 'src/app/a'],
        ['owner', '--policy', 'a', '--policy', 'b', 'src/app/a'],
    ]:
        value = invoke(args, 64)
        assert value['payload'] is None and value['policy_hash'] is None

print(f'{count} real plan/query process/schema checks passed (runtime PATH cleared).')
