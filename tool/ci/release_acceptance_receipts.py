"""Strict expanded release acceptance receipts, including their original log bytes."""
import json
import math
from pathlib import PurePosixPath, PureWindowsPath
import re

from jsonschema import Draft202012Validator
from combine_installations import MAX_FILE, ordinary, read_record, unique_object
from installation_artifact import _sha256
from native_acceptance import FIXTURE_KEYS, suite_commands
from prepare_native_acceptance import FLUTTER, NODE, GIT_URL, GIT_REF, FLUTTER_VERSION

PUB_CASES = [
    ('init', ['init', '--template', 'mixed'], 0, False, None),
    ('validate', ['validate'], 0, False, None), ('node', ['node'], 0, False, None),
    ('export-stdout', ['export', '--format', 'mermaid'], 0, False, None),
    ('export-file', ['export', '--format', 'mermaid', '--out', 'diagram.mmd'], 0, False, None),
    ('typescript', ['check'], 0, True, None),
    ('missing-node', ['check'], 2, False, 'NODE_UNAVAILABLE'),
    ('missing-helper', ['check'], 2, True, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('aliased-helper', ['check'], 2, True, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('restored-typescript', ['check'], 0, True, None),
    ('missing-bridge-validate', ['validate'], 0, False, None),
    ('missing-bridge-export', ['export', '--format', 'mermaid', '--out', 'blocked.mmd'], 2, False, 'EXPORT_WRITE_FAILED'),
    ('missing-bridge-init', ['init', '--template', 'mixed'], 2, False, 'INIT_UNAVAILABLE'),
]
NPM_ASSETS = [
    ('aliased-helper', 2, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('corrupt-helper', 2, 'TYPESCRIPT_HELPER_FAILED'),
    ('missing-compiler', 2, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('aliased-compiler', 2, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
    ('corrupt-compiler', 2, 'TYPESCRIPT_LOAD_FAILED'),
    *[(name, 126, 'launcher-prelaunch') for name in (
        'missing-payload', 'aliased-payload', 'corrupt-payload',
        'missing-manifest', 'aliased-manifest', 'corrupt-manifest')],
    ('restored-payload-help', 0, None),
]
SUITES = ('plan_query', 'cli', 'catalogue_export', 'check', 'dart_check', 'physical_path',
          'alias_wire', 'alias_hop_recheck', 'alias_trace_gap', 'dart_resource', 'runtime',
          'runtime_request', 'runtime_preflight', 'native_asset', 'native_abi', 'native_fault',
          'package_provenance', 'dart_flutter')


def one(root, name):
    paths = list(root.rglob(name))
    if len(paths) != 1:
        raise ValueError(f'Expected one original evidence file: {name}')
    ordinary(paths[0], MAX_FILE)
    return paths[0]


def verified_bytes(path, digest):
    ordinary(path, MAX_FILE)
    if not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest) or _sha256(path) != digest:
        raise ValueError('Original evidence log hash differs')
    return path.read_bytes()


def validate_pub(proof, artifact, target, repository):
    analysis = proof['analysis']
    expected_node = {'version': 'v24.21.0', 'platform': {
        'linux-x64': 'linux', 'macos-arm64': 'darwin', 'windows-x64': 'win32'}[target],
        'arch': 'arm64' if target == 'macos-arm64' else 'x64'}
    if analysis['node'] != expected_node or len(analysis['cases']) != len(PUB_CASES):
        raise ValueError('Pub expanded analysis runtime/inventory differs')
    schemas = repository / 'contracts/json'
    validators = {name: Draft202012Validator(read_record(schemas / (name + '.schema.json')))
                  for name in ('public-result', 'export-diagnostics')}
    for case, (name, args, code, node, error) in zip(analysis['cases'], PUB_CASES):
        if (case['case'] != name or case['arguments'] != args or type(case['exit']) is not int
                or case['exit'] != code or case['node_available'] is not node or case['error'] != error):
            raise ValueError('Pub expanded analysis case differs')
        stdout = verified_bytes(one(artifact, name + '.stdout.log'), case['stdout_sha256'])
        stderr = verified_bytes(one(artifact, name + '.stderr.log'), case['stderr_sha256'])
        export = args[0] == 'export'
        if name == 'export-stdout' and not stdout.endswith(b'flowchart LR\n'):
            raise ValueError('Pub actual Mermaid output differs')
        if export and '--out' in args and stdout:
            raise ValueError('Pub file export unexpectedly wrote stdout')
        if not export and stderr:
            raise ValueError('Pub command emitted unexpected stderr')
        data = stderr if export else stdout
        if not data:
            if export and code == 0 and error is None:
                continue
            raise ValueError('Pub command omitted required JSON evidence')
        value = json.loads(data, object_pairs_hook=unique_object)
        failures = list(validators['export-diagnostics' if export else 'public-result'].iter_errors(value))
        status = 'ok' if code == 0 else ('incomplete' if args[0] == 'check' else 'error')
        if failures or value['command'] != args[0] or value['exit_code'] != code or value['status'] != status:
            raise ValueError('Pub actual JSON schema/command/exit differs')
        if error:
            errors = value['payload']['tool_errors'] if args[0] == 'check' else value['diagnostics']
            if [e['code'] for e in errors] != [error]:
                raise ValueError('Pub actual JSON error codes differ')
        if args[0] == 'check' and value['payload']['analysis_complete'] is not (code == 0):
            raise ValueError('Pub actual analysis completeness differs')


def validate_npm(case, route):
    assets = case['asset_controls']
    expected = [{'case': name, 'exit': code, **({'error': error} if error else {})}
                for name, code, error in NPM_ASSETS]
    if assets != expected or any(type(c['exit']) is not int for c in assets):
        raise ValueError('npm asset-control inventory/results differ')
    corpus = case['corpus_control']
    expected = ({'applicable': True,
                 'selected_path': 'node_modules/archway-architecture-cli/assets/typescript/helper.cjs',
                 'cases': [{'case': 'selected-installed-corpus', 'exit': 2, 'selected_present': True, 'observed_files': 3},
                           {'case': 'excluded-installed-corpus', 'exit': 0, 'selected_present': False, 'observed_files': 2}]}
                if route == 'local' else
                {'applicable': False, 'reason': 'installation-outside-inspected-root', 'cases': []})
    if (corpus != expected or corpus['applicable'] is not expected['applicable']
            or any(type(c['exit']) is not int or type(c['observed_files']) is not int
                   or type(c['selected_present']) is not bool for c in corpus['cases'])):
        raise ValueError('npm selected/excluded installed-corpus controls differ')


def validate_native(proof, report, artifact, source):
    target = proof['target']
    path_type = PureWindowsPath if target == 'windows-x64' else PurePosixPath
    moved = proof['relocation']
    extracted, executed = path_type(moved['extracted']), path_type(moved['executed'])
    if (not extracted.is_absolute() or not executed.is_absolute() or extracted == executed
            or moved['original_removed'] is not True):
        raise ValueError('Native installation was not actually relocated')
    binary = executed / 'bin' / target / ('archway.exe' if target == 'windows-x64' else 'archway')
    acceptance = proof['acceptance']
    if not isinstance(acceptance, dict) or acceptance['source'] != source:
        raise ValueError('Native acceptance source is absent or differs from archive')
    provenance = acceptance['fixtures']
    fixture_path = one(artifact, 'acceptance-fixtures.json')
    verified_bytes(fixture_path, provenance['sha256'])
    fixture = read_record(fixture_path)
    if (fixture != provenance['manifest'] or fixture['target'] != target or fixture['source'] != source
            or type(fixture['schema_version']) is not int or fixture['schema_version'] != 1):
        raise ValueError('Native prepared fixture identity differs')
    pins = fixture['pins']
    if ((pins['flutter']['archive'], pins['flutter']['sha256']) != FLUTTER[target]
            or pins['flutter']['version'] != FLUTTER_VERSION or pins['dart'] != '3.13.3'
            or pins['wrong_node']['version'] != '24.19.0' or pins['wrong_node']['sha256'] != NODE[target][1]
            or pins['git']['url'] != GIT_URL or pins['git']['ref'] != GIT_REF or pins['collection'] != '1.19.1'):
        raise ValueError('Native prepared fixture pins differ')
    harness = path_type(acceptance['source_root'])
    node = path_type(acceptance['node_path'])
    python = path_type(acceptance['python'])
    output = path_type(acceptance['output_root'])
    paths = {key: path_type(fixture[key]) for key in FIXTURE_KEYS}
    if (any(not path.is_absolute() for path in (harness, node, python, output, *paths.values()))
            or harness != path_type(proof['source_root'])
            or proof['node'] != ['v24.21.0', {'linux-x64': 'linux', 'macos-arm64': 'darwin',
                                            'windows-x64': 'win32'}[target],
                                 'arm64' if target == 'macos-arm64' else 'x64']):
        raise ValueError('Native harness/runtime/fixture metadata differs')
    expected_commands = dict(suite_commands(harness, binary, node, paths, output, python=str(python)))
    suites = acceptance['suites']
    if [s['suite'] for s in suites] != list(SUITES):
        raise ValueError('Native acceptance must contain the exact 18-suite inventory')
    expected_fields = {'suite', 'command', 'exit_code', 'timed_out', 'elapsed_seconds',
                       'timeout_seconds', 'stdout', 'stderr', 'stdout_sha256', 'stderr_sha256'}
    for receipt in suites:
        name, command = receipt['suite'], receipt['command']
        if (set(receipt) != expected_fields or type(receipt['exit_code']) is not int
                or receipt['exit_code'] != 0 or receipt['timed_out'] is not False
                or type(receipt['timeout_seconds']) is not int or receipt['timeout_seconds'] != 600
                or type(receipt['elapsed_seconds']) not in (int, float)
                or not math.isfinite(receipt['elapsed_seconds']) or receipt['elapsed_seconds'] < 0
                or not isinstance(command, list) or any(not isinstance(arg, str) for arg in command)
                or [path_type(arg) for arg in command] !=
                   [path_type(arg) for arg in expected_commands[name]]):
            raise ValueError('Native suite failed, timed out, or full command differs from bound harness/fixtures')
        if name == 'dart_check' and '--existing-installation' not in command:
            raise ValueError('Dart native acceptance did not use the extracted installation')
        receipt_path = report.parent / 'acceptance' / (name + '.json')
        if read_record(receipt_path) != receipt:
            raise ValueError('Original native suite receipt differs from report')
        for stream in ('stdout', 'stderr'):
            if receipt[stream] != name + '.' + stream + '.log':
                raise ValueError('Native suite log filename differs')
            verified_bytes(receipt_path.parent / receipt[stream], receipt[stream + '_sha256'])
