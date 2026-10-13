"""Bind installer bytes and original logs to the existing native archive receipt."""
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import re

from jsonschema import Draft202012Validator
from combine_installations import MAX_TOTAL, ordinary, read_record, unique_object
from installation_artifact import _sha256
from release_acceptance_receipts import verified_bytes
from release_source_receipts import validate_execution
from release_installer_phases import validate_phases

CASES = ['install-old', 'upgrade-final', 'installed-command', 'remove', 'foreign-preserved']
WINDOWS_CASES = ['raw-path-registry-types', 'preexisting-path-token', 'foreign-root-refusal',
                 'foreign-command-refusal', 'duplicate-token-refusal', 'root-junction-refusal',
                 'locked-stale-file-failure', 'obsolete-directory-junction-uninstall']


def validate_installer(proof, directory, manifest_sha256):
    receipt = proof.get('installer')
    if not isinstance(receipt, dict):
        raise ValueError('Native installer receipt is missing')
    target = proof['target']
    root = directory / 'installer'
    suffix = {'linux-x64': 'deb', 'macos-arm64': 'pkg', 'windows-x64': 'exe'}[target]
    expected = f'archway-0.1.0-{target}-unsigned.{suffix}'
    artifact = receipt['artifact']
    path = root / expected
    ordinary(path, MAX_TOTAL)
    if (artifact['name'] != expected or type(artifact['size']) is not int
            or artifact['size'] != path.stat().st_size or artifact['sha256'] != _sha256(path)
            or receipt['bundle_manifest_sha256'] != manifest_sha256):
        raise ValueError('Native installer artifact or input manifest differs')
    if receipt['cases'] != CASES + (WINDOWS_CASES if target == 'windows-x64' else []):
        raise ValueError('Native installer lifecycle cases are incomplete')
    old = receipt['old_fixture']
    if (old['version'] != '0.0.0' or old['test_only'] is not True
            or old['removed_file'] != 'obsolete/installer-probe..txt'):
        raise ValueError('Native installer lacks a distinct test-only old generation')
    path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
    compiler = receipt['compiler']
    compiler_name = {'linux-x64': 'dpkg-deb', 'macos-arm64': 'pkgbuild', 'windows-x64': 'ISCC.exe'}[target]
    if (not path_type(compiler['path']).is_absolute()
            or path_type(compiler['path']).name != compiler_name
            or not isinstance(compiler['version'], str) or not compiler['version'].strip()):
        raise ValueError('Native installer compiler identity is missing')
    for digest in [compiler['sha256'], old['manifest_sha256'], old['artifact_sha256']]:
        if not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Native installer compiler/fixture hash is invalid')

    seen = set()
    def streams(command):
        if (not isinstance(command['arguments'], list) or not command['arguments']
                or not all(isinstance(a, str) for a in command['arguments'])
                or type(command['exit']) is not int):
            raise ValueError('Native installer command record is invalid')
        result = {}
        for stream in ('stdout', 'stderr'):
            name = command[stream]
            if not isinstance(name, str) or not re.fullmatch('[A-Za-z0-9_.-]+\\.log', name) or name in seen:
                raise ValueError('Native installer log name is invalid or reused')
            seen.add(name)
            result[stream] = verified_bytes(root / name, command[stream + '_sha256'])
        return result
    if not isinstance(receipt['commands'], list) or not receipt['commands']:
        raise ValueError('Native installer build/lifecycle logs are missing')
    for command in receipt['commands']:
        streams(command)
        if target != 'windows-x64' and command['exit'] != 0:
            raise ValueError('Native installer lifecycle command failed')
    validate_phases(proof, root, path_type)
    installed = receipt['installed']
    if (installed['manifest_sha256'] != manifest_sha256
            or installed['native_commands'] != ['help', 'version', 'init', 'validate', 'export']
            or [(c['case'], c['exit']) for c in installed['typescript']] !=
               [('clean', 0), ('dependency-violation', 1), ('unsupported-option', 64)]
            or installed['runtime_controls'] != [
                {'case': name, 'exit': 2, 'errors': ['NODE_UNAVAILABLE']}
                for name in ['missing-node', 'wrong-node']]):
        raise ValueError('Native installed command coverage is incomplete')
    processes = installed['processes']
    if len(processes) != 10 or not path_type(installed['binary']).is_absolute():
        raise ValueError('Native installed command process inventory differs')
    exits = [0, 0, 0, 0, 0, 0, 1, 64, 2, 2]
    commands = ['--help', '--version', 'init', 'validate', 'export', 'check', 'check', 'check', 'check', 'check']
    schemas = Path(__file__).resolve().parents[2] / 'contracts/json'
    validators = {name: Draft202012Validator(read_record(schemas / (name + '.schema.json')))
                  for name in ('public-result', 'export-diagnostics')}
    for index, (process, code, command) in enumerate(zip(processes, exits, commands)):
        arguments = process['arguments']
        if (process['exit'] != code or arguments[0] != installed['binary']
                or (arguments[1:] != [command] if index < 2 else
                    len(arguments) < 4 or arguments[1] != '--root' or arguments[3] != command)):
            raise ValueError('Native installed process command/exit differs')
        data = streams(process)
        if index == 0:
            valid = data['stdout'].startswith(b'archway [--root ROOT]') and not data['stderr']
        elif index == 1:
            valid = data['stdout'] in (b'archway 0.1.0\n', b'archway 0.1.0\r\n') and not data['stderr']
        elif index == 4:
            value = json.loads(data['stderr'], object_pairs_hook=unique_object)
            valid = data['stdout'].endswith(b'flowchart LR\n') and value['exit_code'] == 0
        else:
            value = json.loads(data['stdout'], object_pairs_hook=unique_object)
            valid = value['command'] == command and value['exit_code'] == code and not data['stderr']
            if index >= 8:
                valid = valid and [e['code'] for e in value['payload']['tool_errors']] == ['NODE_UNAVAILABLE']
        if index >= 2:
            schema = validators['export-diagnostics' if index == 4 else 'public-result']
            expected_status = {0:'ok',1:'negative',64:'usage_error',2:'incomplete'}[code]
            valid = valid and not list(schema.iter_errors(value)) and value.get('status') == expected_status
            payload = value.get('payload')
            if index == 2:
                valid = valid and isinstance(payload, dict) and payload.get('outcome') == 'created' and payload.get('template') == 'mixed'
            elif index == 3:
                valid = valid and payload == {'policy_valid':True,'projects':0,'nodes':0}
            elif index == 4:
                valid = valid and payload == {'format':'mermaid','out':None}
            elif index == 7:
                valid = valid and payload is None
            else:
                valid = valid and isinstance(payload, dict) and payload.get('policy_valid') is True and payload.get('analysis_complete') is (code != 2)
        if not valid:
            raise ValueError('Native installed original command output differs')
    suites = installed['suites']
    if [suite['suite'] for suite in suites] != ['plan_query', 'dart_check']:
        raise ValueError('Installed query/Dart suite coverage differs')
    acceptance = proof['acceptance']
    for suite in suites:
        name = suite['suite']
        command = [acceptance['python'], str(path_type(acceptance['source_root']) /
                   'test' / (name + '_process_smoke.py')), installed['binary']]
        if name == 'dart_check':
            command += [acceptance['fixtures']['manifest']['dart_sdk'],
                        acceptance['node_path'], '--existing-installation']
        validate_execution(suite, command, root / 'suites', path_type)
    return path
