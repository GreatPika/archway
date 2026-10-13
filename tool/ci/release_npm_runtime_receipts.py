"""Strict npm command parity, bridge, and genuine negative-runtime receipts."""
from pathlib import PurePosixPath, PureWindowsPath
import re

from combine_installations import read_record
from prepare_native_acceptance import NODE
from release_acceptance_receipts import one


def validate_npm_runtime(case, target, artifact):
    expected = [{'case': name, 'arguments': args, 'exit': code, 'native_parity': True}
                for name, args, code in [
                    ('validate-native-parity', ['validate'], 0), ('node-native-parity', ['node'], 0),
                    ('export-native-parity', ['export', '--format', 'mermaid'], 0),
                    ('literal-argv-native-parity', ['unknown; $(touch should-not-exist) & café'], 64)]]
    expected += [{'case': 'missing-bridge-validate', 'exit': 0},
                 {'case': 'missing-bridge-export', 'exit': 2, 'error': 'EXPORT_WRITE_FAILED'},
                 {'case': 'restored-bridge-export', 'exit': 0}]
    commands = case['command_controls']
    if (commands != expected or any(type(c['exit']) is not int for c in commands)
            or any(c.get('native_parity', True) is not True for c in commands)):
        raise ValueError('npm command/argv/native parity or bridge controls differ')
    runtime = case['runtime_controls']
    record = read_record(one(artifact, 'runtime.json'))
    platform, arch = {'linux-x64': ('linux', 'x64'), 'macos-arm64': ('darwin', 'arm64'),
                      'windows-x64': ('win32', 'x64')}[target]
    path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
    digest = record['executable_sha256']
    if (record['target'] != target or record['version'] != '24.19.0'
            or record['url'] != 'https://nodejs.org/dist/v24.19.0/node-v24.19.0-' + NODE[target][0]
            or record['archive_sha256'] != NODE[target][1]
            or not path_type(record['executable']).is_absolute()
            or not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)
            or runtime['wrong_node'] != {'version': '24.19.0', 'platform': platform,
                                         'arch': arch, 'executable_sha256': digest}):
        raise ValueError('npm negative Node identity differs from official prepared artifact')
    cases = runtime['cases']
    if len(cases) != 4 or type(cases[1]['exit']) is not int or cases[1]['exit'] == 0:
        raise ValueError('npm missing launcher Node did not fail')
    expected = [
        {'case': 'wrong-analysis-node', 'invocation': 'installed-route', 'exit': 2, 'error': 'NODE_UNAVAILABLE'},
        {'case': 'missing-launcher-node', 'invocation': 'installed-route', 'exit': cases[1]['exit'],
         'launcher_stderr_only': True},
        {'case': 'native-supplement-missing-node-check', 'invocation': 'installed-native-supplement',
         'exit': 2, 'error': 'NODE_UNAVAILABLE'},
        {'case': 'native-supplement-no-node-validate', 'invocation': 'installed-native-supplement', 'exit': 0}]
    if cases != expected or cases[1]['launcher_stderr_only'] is not True or any(type(c['exit']) is not int for c in cases):
        raise ValueError('npm runtime failure/supplemental native controls differ')
