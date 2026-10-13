"""Genuine wrong-runtime route controls; preparation is always explicit."""
import hashlib
import json
import subprocess

from npm_local_analysis import assert_result, snapshot


def exercise(shim, root, cwd, installed, environment, run, target, wrong_node):
    assert wrong_node is not None, 'Supply a prepared genuine Node 24.19.0 with --wrong-node'
    assert wrong_node.is_file() and wrong_node.resolve() == wrong_node
    version = subprocess.run([str(wrong_node), '-p',
        'JSON.stringify([process.version,process.platform,process.arch])'],
        cwd=cwd, env=environment, capture_output=True, timeout=30)
    expected = ['v24.19.0', {'linux-x64': 'linux', 'macos-arm64': 'darwin',
                            'windows-x64': 'win32'}[target],
                'arm64' if target == 'macos-arm64' else 'x64']
    assert version.returncode == 0 and version.stderr == b''
    assert json.loads(version.stdout) == expected, 'Wrong negative-control runtime'
    before = snapshot(root), snapshot(cwd), snapshot(installed)
    result = run([str(shim), '--root', str(root), 'check'], cwd,
                 {**environment, 'PATH': str(wrong_node.parent)}, expected_exit=2)
    value = assert_result(result, 2, 'incomplete')
    assert value['payload']['analysis_complete'] is False
    assert [e['code'] for e in value['payload']['tool_errors']] == ['NODE_UNAVAILABLE']
    assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
    cases = [{'case': 'wrong-analysis-node', 'invocation': 'installed-route',
              'exit': 2, 'error': 'NODE_UNAVAILABLE'}]
    missing = root.parent / 'missing node runtime'
    assert not missing.exists()
    no_node = {**environment, 'PATH': str(missing)}
    # An npm route itself needs Node. This is a launcher failure, never a
    # successful policy result or a core NODE_UNAVAILABLE JSON envelope.
    launch = run([str(shim), '--help'], cwd, no_node, expected_exit=None)
    assert launch.returncode != 0 and launch.stdout == b'' and b'node' in launch.stderr.lower()
    cases.append({'case': 'missing-launcher-node', 'invocation': 'installed-route',
                  'exit': launch.returncode, 'launcher_stderr_only': True})
    binary = installed / 'bin' / target / ('archway.exe' if target == 'windows-x64' else 'archway')
    # Supplemental direct native calls do not claim that npm/shims work without Node.
    result = subprocess.run([str(binary), '--root', str(root), 'check'], cwd=cwd, env=no_node,
                            capture_output=True, timeout=30)
    value = assert_result(result, 2, 'incomplete')
    assert value['payload']['analysis_complete'] is False
    assert [e['code'] for e in value['payload']['tool_errors']] == ['NODE_UNAVAILABLE']
    cases.append({'case': 'native-supplement-missing-node-check',
                  'invocation': 'installed-native-supplement', 'exit': 2, 'error': 'NODE_UNAVAILABLE'})
    result = subprocess.run([str(binary), '--root', str(root), 'validate'], cwd=cwd, env=no_node,
                            capture_output=True, timeout=30)
    assert result.returncode == 0 and result.stderr == b''
    value = json.loads(result.stdout)
    assert value['command'] == 'validate' and value['exit_code'] == 0 and value['status'] == 'ok'
    cases.append({'case': 'native-supplement-no-node-validate',
                  'invocation': 'installed-native-supplement', 'exit': 0})
    assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
    with wrong_node.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'wrong_node': {'version': '24.19.0', 'platform': expected[1], 'arch': expected[2],
                           'executable_sha256': digest}, 'cases': cases}
