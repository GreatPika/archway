"""Compare caller-bound npm transport with its selected installed native core."""
import json
import subprocess

from npm_local_analysis import snapshot


def exercise(shim, root, cwd, installed, environment, run, target):
    binary = installed / 'bin' / target / ('archway.exe' if target == 'windows-x64' else 'archway')
    cases = []
    for name, arguments, code in [
        ('validate-native-parity', ['validate'], 0),
        ('node-native-parity', ['node'], 0),
        ('export-native-parity', ['export', '--format', 'mermaid'], 0),
        ('literal-argv-native-parity', ['unknown; $(touch should-not-exist) & café'], 64),
    ]:
        before = snapshot(root), snapshot(cwd), snapshot(installed)
        native = subprocess.run([str(binary), '--root', str(root), *arguments],
                                cwd=cwd, env=environment, capture_output=True, timeout=30)
        assert native.returncode == code, 'Native reference exit differs from contract'
        wrapped = run([str(shim), '--root', str(root), *arguments], cwd, environment,
                      expected_exit=code)
        assert (wrapped.returncode, wrapped.stdout, wrapped.stderr) == (
            native.returncode, native.stdout, native.stderr), 'Installed route changed core argv/streams/exit'
        assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
        assert not (cwd / 'should-not-exist').exists()
        if name == 'export-native-parity':
            mermaid = native.stdout
        cases.append({'case': name, 'arguments': arguments, 'exit': code, 'native_parity': True})
    bridge_name = {'linux-x64': 'libarchway_io.so', 'macos-arm64': 'libarchway_io.dylib',
                   'windows-x64': 'archway_io.dll'}[target]
    bridge = installed / 'native' / target / bridge_name
    saved = bridge.with_suffix(bridge.suffix + '.control-saved')
    assert not saved.exists()
    before = snapshot(root), snapshot(cwd), snapshot(installed)
    bridge.rename(saved)
    output = root / 'bridge output café.mmd'
    assert not output.exists()
    try:
        valid = run([str(shim), '--root', str(root), 'validate'], cwd, environment)
        value = json.loads(valid.stdout)
        assert valid.stderr == b'' and value['command'] == 'validate'
        assert value['exit_code'] == 0 and value['status'] == 'ok'
        failed = run([str(shim), '--root', str(root), 'export', '--format', 'mermaid',
                      '--out', output.name], cwd, environment, expected_exit=2)
        assert failed.stdout == b'' and failed.stderr.count(b'\n') == 1
        value = json.loads(failed.stderr)
        assert value['command'] == 'export' and value['exit_code'] == 2 and value['status'] == 'error'
        assert [d['code'] for d in value['diagnostics']] == ['EXPORT_WRITE_FAILED']
        assert not output.exists(), 'Missing bridge must not create output'
        cases += [{'case': 'missing-bridge-validate', 'exit': 0},
                  {'case': 'missing-bridge-export', 'exit': 2, 'error': 'EXPORT_WRITE_FAILED'}]
    finally:
        saved.rename(bridge)
    assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
    try:
        restored = run([str(shim), '--root', str(root), 'export', '--format', 'mermaid',
                        '--out', output.name], cwd, environment)
        assert restored.stdout == restored.stderr == b''
        assert output.read_bytes() == mermaid
        cases.append({'case': 'restored-bridge-export', 'exit': 0})
    finally:
        output.unlink(missing_ok=True)
    assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
    return cases
