"""Actual native AOT catalogue/export transport, schema, safety and runtime absence.

This is supplementary CLI.run process coverage, not release certification.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

from jsonschema import Draft202012Validator
from windows_output_lock import exclusive_file_lock

repo = Path(__file__).resolve().parents[1]
executable = str(Path(sys.argv[1]).resolve())
contracts = repo / 'contracts/json'
public = Draft202012Validator(json.loads((contracts / 'public-result.schema.json').read_text()))
export = Draft202012Validator(json.loads((contracts / 'export-diagnostics.schema.json').read_text()))
count = 0

with tempfile.TemporaryDirectory(prefix='archway-export-') as temp:
    root = Path(temp).resolve() / 'root café'
    root.mkdir()
    cwd = Path(temp).resolve() / 'other cwd'
    cwd.mkdir()
    policy = root / 'architecture.yaml'

    def invoke(args, expected, *, fault=None):
        global count
        result = subprocess.run([executable, '--root', str(root), *args], cwd=cwd,
                                env={**os.environ, 'PATH': str(cwd / 'no-runtime-here')},
                                capture_output=True, timeout=10,
                                **({'preexec_fn': fault} if fault else {}))
        assert result.returncode == expected, (args, result)
        if args[0] == 'export':
            if expected:
                assert result.stdout == b''
            if result.stderr:
                assert result.stderr.count(b'\n') == 1 and result.stderr.endswith(b'\n')
                value = json.loads(result.stderr)
                export.validate(value)
                assert value['exit_code'] == expected
                assert value['tool_versions']['node'] is None
        else:
            assert result.stderr == b''
            assert result.stdout.count(b'\n') == 1 and result.stdout.endswith(b'\n')
            value = json.loads(result.stdout)
            public.validate(value)
            assert value['exit_code'] == expected
        count += 1
        return result

    policy.write_bytes((contracts / 'fixtures/policy-empty.json').read_bytes())
    empty = invoke(['export', '--format', 'mermaid'], 0)
    assert empty.stdout.endswith(b'flowchart LR\n')
    assert json.loads(empty.stderr)['diagnostics'][0]['code'] == 'EMPTY_PLAN'
    assert json.loads(invoke(['node'], 0).stdout)['payload'] == {
        'mode': 'catalogue', 'nodes': [], 'total': 0, 'omitted': 0, 'offset': 0, 'limit': None}

    nodes = [{'id': f'n{i:04d}', 'responsibility': f'Node {i}', 'owns': [],
              'public': [], 'allows': [f'n{(i + 1) % 1001:04d}']} for i in range(1001)]
    policy.write_text(json.dumps({'version': 1, 'projects': [], 'scope': [], 'exclude': [], 'nodes': nodes[::-1]}))
    catalogue = json.loads(invoke(['node'], 0).stdout)
    assert len(catalogue['payload']['nodes']) == 1001 and catalogue['payload']['omitted'] == 0
    assert catalogue['payload']['nodes'][0]['id'] == 'n0000'
    assert catalogue['payload']['nodes'][-1]['id'] == 'n1000'
    assert catalogue['policy_hash'] == 'sha256:' + hashlib.sha256(policy.read_bytes()).hexdigest()
    for offset, limit, returned in [(1, 2, 2), (1000, 8, 1), (1002, 1, 0),
                                    (1, 9223372036854775807, 1000),
                                    (9223372036854775807, 9223372036854775807, 0)]:
        page = json.loads(invoke(['node', f'--offset={offset}', f'--limit={limit}'], 0).stdout)['payload']
        assert (page['total'], page['omitted'], page['offset'], page['limit']) == (1001, 1001-returned, offset, limit)
        assert len(page['nodes']) == returned
    diagram = invoke(['export', '--format', 'mermaid'], 0)
    assert diagram.stdout.count(b' --> ') == 1001 and diagram.stdout.count(b'["') == 1001
    assert b'n1000 --> n0\n' in diagram.stdout
    assert invoke(['export', '--format=mermaid'], 0).stdout == diagram.stdout
    assert json.loads(diagram.stderr)['diagnostics'][0]['code'] == 'POLICY_CYCLE'
    file_args = ['export', '--format', 'mermaid', '--out', 'graph.mmd']
    invoke(file_args, 0)
    assert (root / 'graph.mmd').read_bytes() == diagram.stdout
    invoke(file_args, 2)
    assert (root / 'graph.mmd').read_bytes() == diagram.stdout
    invoke([*file_args, '--overwrite'], 0)
    assert (root / 'graph.mmd').read_bytes() == diagram.stdout
    (root / 'link.mmd').symlink_to('missing-target')
    conflict = invoke(['export', '--format', 'mermaid', '--out', 'link.mmd'], 2)
    assert json.loads(conflict.stderr)['diagnostics'][-1]['code'] == 'EXPORT_TARGET_EXISTS'
    assert (root / 'link.mmd').is_symlink() and not (root / 'missing-target').exists()
    invoke(['export', '--format', 'mermaid', '--out', 'missing/graph.mmd'], 2)

    outside = Path(temp).resolve() / 'outside'
    outside.mkdir()
    (root / 'escape').symlink_to(outside, target_is_directory=True)
    (outside / 'old.mmd').write_text('outside work')
    for name, flags in [('new.mmd', []), ('old.mmd', ['--overwrite'])]:
        invoke(['export', '--format', 'mermaid', '--out', f'escape/{name}', *flags], 2)
    assert not (outside / 'new.mmd').exists()
    assert (outside / 'old.mmd').read_text() == 'outside work'
    (root / 'nested').mkdir()
    root_alias = Path(temp).resolve() / 'selected-root-link'
    root_alias.symlink_to(root, target_is_directory=True)
    selected = subprocess.run([executable, '--root', str(root_alias), 'export', '--format', 'mermaid',
                               '--out', 'nested/graph.mmd'], capture_output=True, timeout=10,
                              env={**os.environ, 'PATH': str(cwd / 'no-runtime-here')})
    assert selected.returncode == 0 and selected.stdout == b''
    export.validate(json.loads(selected.stderr))
    assert (root / 'nested/graph.mmd').read_bytes() == diagram.stdout
    count += 1

    # Non-regular output rejection is required on every target.
    (root / 'directory.mmd').mkdir()
    invoke(['export', '--format', 'mermaid', '--out', 'directory.mmd', '--overwrite'], 2)
    assert (root / 'directory.mmd').is_dir()
    if os.name == 'nt':
        # Windows has no filesystem FIFO or RLIMIT_FSIZE. A real no-sharing
        # handle induces an output I/O failure without changing ACLs/privileges.
        locked = root / 'locked.mmd'
        locked.write_bytes(b'keep existing output')
        with exclusive_file_lock(locked):
            failure = invoke(['export', '--format', 'mermaid', '--out', 'locked.mmd', '--overwrite'], 2)
        assert json.loads(failure.stderr)['diagnostics'][-1]['code'] == 'EXPORT_WRITE_FAILED'
        assert locked.read_bytes() == b'keep existing output'
        print('Windows mechanisms: non-regular directory rejection and real sharing conflict; '
              'POSIX FIFO/RLIMIT_FSIZE are inapplicable. Partial-write/flush/close faults '
              'are required separately in native_fault_process_smoke.', flush=True)
    else:
        import resource
        import signal
        os.mkfifo(root / 'pipe.mmd')
        invoke(['export', '--format', 'mermaid', '--out', 'pipe.mmd', '--overwrite'], 2)

        def limit_output():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))

        failure = invoke(['export', '--format', 'mermaid', '--out', 'partial.mmd'], 2, fault=limit_output)
        assert json.loads(failure.stderr)['diagnostics'][-1]['code'] == 'EXPORT_WRITE_FAILED'
        assert (root / 'partial.mmd').read_bytes() == b'%'

    # Concurrent processes must have exactly one winner; no loser truncates it.
    def contend(_):
        return subprocess.run([executable, '--root', str(root), 'export', '--format', 'mermaid', '--out', 'race.mmd'],
                              capture_output=True, timeout=10, env={**os.environ, 'PATH': str(cwd / 'no-runtime-here')})
    with ThreadPoolExecutor(max_workers=8) as pool:
        outcomes = list(pool.map(contend, range(8)))
    assert sorted(p.returncode for p in outcomes) == [0, 2, 2, 2, 2, 2, 2, 2]
    assert (root / 'race.mmd').read_bytes() == diagram.stdout
    for outcome in outcomes:
        assert outcome.stdout == b''
        export.validate(json.loads(outcome.stderr))
    count += 8

    for args in [['export'], ['export', '--format', 'json'],
                 ['export', '--format', 'mermaid', '--overwrite'],
                 ['export', '--format', 'mermaid', '--out', '../outside'],
                 ['node', '--limit', '0'], ['node', '--offset', '-1']]:
        invoke(args, 64)
    policy.write_text('[')
    invalid = invoke(['export', '--format', 'mermaid', '--out', 'invalid.mmd'], 2)
    value = json.loads(invalid.stderr)
    assert value['status'] == 'invalid_policy' and value['policy_hash'] is not None
    assert not (root / 'invalid.mmd').exists()
    policy.unlink()
    assert json.loads(invoke(['export', '--format', 'mermaid'], 2).stderr)['status'] == 'error'
    missing_root = subprocess.run([executable, '--root', str(root / 'missing'), 'export', '--format', 'mermaid'], capture_output=True)
    assert missing_root.returncode == 64 and missing_root.stdout == b''
    export.validate(json.loads(missing_root.stderr))
    assert json.loads(missing_root.stderr)['payload'] == {'format': 'mermaid', 'out': None}
    count += 1
print(f'{count} native AOT catalogue/export/schema/safety cases passed')
