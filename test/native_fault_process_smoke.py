"""Native fault regressions on Linux x64, macOS arm64 and Windows x64.

Real CLI seams, not OS certification.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from installation_staging import stage_installation
from native_process_support import native_target, build_library

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='archway-native-fault-') as temp:
    base = Path(temp).resolve()
    binary = stage_installation(Path(sys.argv[1]), base / 'bundle')
    target, library, _ = native_target()
    asset = base / 'bundle/native' / target / library
    windows = target == 'windows-x64'
    fixture = 'native_fault_windows_fixture.c' if windows else 'native_fault_fixture.c'
    build_library(repo / 'test' / fixture, asset)
    count = 0

    def invoke(root, args, fault, expected):
        global count
        log = base / 'close.log'
        log.write_text('')
        env = {**os.environ, 'ARCHWAY_TEST_FAULT': fault, 'ARCHWAY_TEST_CLOSE_LOG': str(log)}
        result = subprocess.run([str(binary), '--root', str(root), *args], env=env,
                                capture_output=True, timeout=10)
        assert result.returncode == expected, (fault, result)
        count += 1
        return result, log.read_text().splitlines()

    root = base / 'export'
    root.mkdir()
    (root / 'architecture.yaml').write_text('version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
    baseline, closed = invoke(root, ['export', '--format', 'mermaid'], '', 0)
    assert not closed
    assert json.loads(baseline.stderr)['diagnostics'][0]['code'] == 'EMPTY_PLAN'
    output = root / 'out.mmd'
    for fault in ['partial', 'aborted' if windows else 'interrupted', 'zero', 'flush', 'close', 'validate']:
        output.write_text('keep this')
        result, closed = invoke(root, ['export', '--format', 'mermaid', '--out', 'out.mmd', '--overwrite'],
                                fault, 0 if fault in ['partial', 'interrupted'] else 2)
        assert result.stdout == b''
        assert closed == ['file', 'directory'], (fault, closed)
        if result.returncode:
            assert json.loads(result.stderr)['diagnostics'][-1]['code'] == 'EXPORT_WRITE_FAILED'
        else:
            assert json.loads(result.stderr)['diagnostics'][0]['code'] == 'EMPTY_PLAN'
        expected = b'keep this' if fault == 'validate' else b'' if fault in ['zero', 'aborted'] else baseline.stdout
        assert output.read_bytes() == expected, fault

    for fault in ['partial', 'aborted' if windows else 'interrupted', 'zero', 'flush', 'close', 'observe']:
        root = base / ('init-' + fault)
        root.mkdir()
        success = fault in ['partial', 'interrupted']
        result, closed = invoke(root, ['init', '--template', 'mixed'], fault, 0 if success else 2)
        assert result.stderr == b''
        value = json.loads(result.stdout)
        payload = value['payload']
        assert payload['outcome'] == ('created' if success else 'partial'), value
        created = ['architecture.yaml', 'ARCHITECTURE.md'] if success else ['architecture.yaml']
        assert payload['created_paths'] == created, value
        assert payload['residual_paths'] == ([] if success else created), value
        assert sorted(p.name for p in root.iterdir()) == sorted(created)
        assert closed == (['file', 'file', 'directory'] if success else ['file', 'directory']), (fault, closed)
        if success:
            assert (root / 'architecture.yaml').read_text() == '# Archway: mixed template\nversion: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n'
        if fault in ['zero', 'observe', 'aborted']:
            assert (root / 'architecture.yaml').read_bytes() == b''
    alias = base / 'alias'
    alias.symlink_to(root, target_is_directory=True)
    result, closed = invoke(alias, ['validate'], 'alias_invalid' if windows else 'alias_full', 2)
    assert result.stderr == b'' and not closed
    diagnostic = json.loads(result.stdout)['diagnostics'][0]
    assert diagnostic['code'] == 'ROOT_ACCESS_FAILED'
    expected_message = 'win32 4392' if windows else 'Symbolic link target exceeds limit'
    assert expected_message in diagnostic['message'], diagnostic
    # Negative control: a bridge that retries an already-consumed handle must
    # be distinguishable from the valid close-once implementation above.
    _, _, source_name = native_target()
    original_source = (repo / 'native' / source_name).read_text()
    close_once = ('return CloseHandle(handle(value)) ? ok(0) : win32_failed(GetLastError());'
                  if windows else 'return close(descriptor(handle)) < 0 ? failed(errno) : ok(0);')
    retry = ('if (!CloseHandle(handle(value))) { DWORD error = GetLastError(); '
             '(void)CloseHandle(handle(value)); return win32_failed(error); } return ok(0);'
             if windows else 'if (close(descriptor(handle)) < 0) { int error = errno; '
             '(void)close(descriptor(handle)); return failed(error); } return ok(0);')
    assert original_source.count(close_once) == 1
    mutant_bridge = base / 'retry_bridge.c'
    mutant_bridge.write_text(original_source.replace(close_once, retry))
    fixture_source = (repo / 'test' / fixture).read_text()
    include = '#include "' + source_name + '"'
    assert fixture_source.count(include) == 1
    mutant_fixture = base / 'retry_fixture.c'
    mutant_fixture.write_text(fixture_source.replace(include,
        '#include "' + mutant_bridge.as_posix() + '"'))
    build_library(mutant_fixture, asset)
    mutant_root = base / 'mutant-export'
    mutant_root.mkdir()
    (mutant_root / 'architecture.yaml').write_text(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
    result, closed = invoke(mutant_root,
        ['export', '--format', 'mermaid', '--out', 'out.mmd'], 'close', 2)
    assert json.loads(result.stderr)['diagnostics'][-1]['code'] == 'EXPORT_WRITE_FAILED'
    assert closed == ['file', 'invalid' if windows else 'directory', 'directory'], closed
print(f'{count} {target} native fault CLI cases passed')
