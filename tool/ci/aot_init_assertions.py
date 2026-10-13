"""Shared assertions for genuine native AOT init acceptance probes.

Expected output comes from contracts/json/decision.md and the mixed template.
Both manually relocated and maintainer-assembled installations use this control.
"""
import json
import os
import subprocess


def assert_aot_init(binary, base, *, command=None, environment=None, label='AOT', timeout=30):
    cwd = base / 'unrelated cwd ü'
    root = base / 'empty project café'
    cwd.mkdir()
    root.mkdir()
    assert list(root.iterdir()) == []
    runtime_path = base / 'no-runtime-here'
    assert runtime_path.is_absolute() and not runtime_path.exists()
    # Retain SystemRoot and other OS essentials while excluding external runtimes.
    arguments = [
        str(binary), '--root', str(root), 'init', '--template', 'mixed',
    ]
    result = subprocess.run(command(arguments) if command else arguments,
        cwd=cwd, env=environment if environment is not None else {**os.environ, 'PATH': str(runtime_path)},
        capture_output=True, timeout=timeout)
    print(f'{label} init exit: {result.returncode}')
    print(f'{label} stdout: {result.stdout!r}')
    print(f'{label} stderr: {result.stderr!r}')
    assert result.returncode == 0, f'Real {label} init must succeed.'
    assert result.stderr == b''
    assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1
    assert not result.stdout.startswith(b'\xef\xbb\xbf')
    value = json.loads(result.stdout.decode('utf-8'))
    assert value['schema_version'] == 1 and value['command'] == 'init'
    assert value['status'] == 'ok' and value['exit_code'] == 0
    assert value['diagnostics'] == []
    assert value['payload'] == {
        'template': 'mixed', 'dry_run': False, 'outcome': 'created',
        'planned_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
        'planned_files': [],
        'created_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
        'residual_paths': [], 'conflicting_paths': [],
    }
    assert sorted(path.name for path in root.iterdir()) == [
        'ARCHITECTURE.md', 'architecture.yaml']
    assert (root / 'architecture.yaml').read_bytes() == (
        b'# Archway: mixed template\nversion: 1\nprojects: []\nscope: []\n'
        b'exclude: []\nnodes: []\n')
    guide = (root / 'ARCHITECTURE.md').read_text(encoding='utf-8')
    assert guide.startswith('# Architecture agent workflow\n')
    assert 'Init never overwrites or merges files.' in guide
    assert 'Init does not edit AGENTS.md, CI, or editor settings.' in guide
    assert list(cwd.iterdir()) == []
    return result
