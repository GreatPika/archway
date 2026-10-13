"""Bind full source-test proof to exact checkout, archive assets and original events."""
import json
import math
import re
from pathlib import PurePosixPath, PureWindowsPath
import subprocess

from combine_installations import MAX_FILE, ordinary, read_record, unique_object
from installation_artifact import _sha256
from native_source_acceptance import summarize_tests
from release_acceptance_receipts import verified_bytes


def validate_execution(receipt, command, directory, path_type):
    fields = {'suite', 'command', 'exit_code', 'timed_out', 'elapsed_seconds', 'timeout_seconds',
              'stdout', 'stderr', 'stdout_sha256', 'stderr_sha256'}
    if (set(receipt) != fields or type(receipt['exit_code']) is not int or receipt['exit_code'] != 0
            or receipt['timed_out'] is not False or type(receipt['timeout_seconds']) is not int
            or receipt['timeout_seconds'] != 600 or type(receipt['elapsed_seconds']) not in (int, float)
            or not math.isfinite(receipt['elapsed_seconds']) or receipt['elapsed_seconds'] < 0
            or not isinstance(receipt['command'], list) or len(receipt['command']) != len(command)
            or path_type(receipt['command'][0]) != path_type(command[0])
            or receipt['command'][1:] != command[1:]):
        raise ValueError('Source-suite execution failed, timed out, or command differs')
    name = receipt['suite']
    if read_record(directory / (name + '.json')) != receipt:
        raise ValueError('Original source-suite execution receipt differs')
    streams = {}
    for stream in ('stdout', 'stderr'):
        if receipt[stream] != name + '.' + stream + '.log':
            raise ValueError('Source-suite log name differs')
        streams[stream] = verified_bytes(directory / receipt[stream], receipt[stream + '_sha256'])
    return streams


def validate_source(proof, report, native_manifest, repository):
    source = proof['acceptance']['source_suite']
    identity, target = proof['source'], proof['target']
    if (source['source'] != identity or source['target'] != target
            or native_manifest['source'] != identity or native_manifest['target'] != target):
        raise ValueError('Source-suite/archive identity differs')
    path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
    fixtures = proof['acceptance']['fixtures']['manifest']
    dart = path_type(fixtures['dart_sdk']) / 'bin' / ('dart.exe' if target == 'windows-x64' else 'dart')
    snapshot = path_type(source['snapshot_root'])
    if (not snapshot.is_absolute() or snapshot == path_type(proof['source_root'])
            or path_type(source['dart']) != dart or source['snapshot_manifest'] != 'source-files.json'):
        raise ValueError('Source-suite snapshot or Dart selection differs')
    for key, name in [('git_fixture', 'git-fixture'), ('flutter_fixture', 'flutter-fixture')]:
        variable = 'ARCHWAY_PUB_GIT_FIXTURE' if key == 'git_fixture' else 'ARCHWAY_FLUTTER_FIXTURE'
        if path_type(fixtures['environment'][variable]) != path_type(fixtures[key]):
            raise ValueError('Mandatory source fixture environment differs')
        if set(fixtures['readiness'][name]) != {'pubspec.yaml', 'pubspec.lock', '.dart_tool/package_config.json'}:
            raise ValueError('Mandatory Git/Flutter fixture preparation is incomplete')
        if any(not isinstance(v, str) or not re.fullmatch('[0-9a-f]{64}', v)
               for v in fixtures['readiness'][name].values()):
            raise ValueError('Mandatory source fixture readiness hash is malformed')
    directory = report.parent / 'acceptance'
    snapshot_path = directory / 'source-files.json'
    verified_bytes(snapshot_path, source['snapshot_manifest_sha256'])
    saved = read_record(snapshot_path)
    tracked = subprocess.run(['git', '-C', str(repository), 'ls-files', '-z'],
                             check=True, capture_output=True, timeout=30).stdout.decode().split('\0')
    current = {}
    for name in filter(None, tracked):
        ordinary(repository / name, MAX_FILE)
        current[name] = _sha256(repository / name)
    if saved != current:
        raise ValueError('Source snapshot manifest differs from exact tracked checkout')
    assets = {name: entry['sha256'] for name, entry in native_manifest['files'].items()
              if name.startswith(('assets/typescript/vendor/', 'native/' + target + '/'))}
    if not assets or source['assets'] != assets:
        raise ValueError('Source-suite assets differ from verified native archive bytes')
    if source['preparation']['suite'] != 'source-pub-get' or source['execution']['suite'] != 'source-tests':
        raise ValueError('Source-suite execution inventory differs')
    validate_execution(source['preparation'], [str(dart), '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
                       directory, path_type)
    logs = validate_execution(source['execution'], [str(dart), 'test', '--reporter=json'], directory, path_type)
    events = [json.loads(line, object_pairs_hook=unique_object) for line in logs['stdout'].splitlines()]
    expected_files = {name for name in current if name.startswith('test/') and name.endswith('_test.dart')}
    observed = summarize_tests(events, expected_files, target)
    if not expected_files or observed != source['tests']:
        raise ValueError('Source test inventory/results/OS skip summary differs from original JSON events')
