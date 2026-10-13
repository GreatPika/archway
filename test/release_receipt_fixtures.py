"""Synthetic receipt fixtures only; these never establish executable acceptance."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
from prepare_native_acceptance import FLUTTER, NODE, GIT_URL, GIT_REF


def native_fixture(directory, target, source):
    base = 'C:/fixture' if target == 'windows-x64' else '/fixture'
    executed = base + '/relocated café installation'
    manifest = {'schema_version': 1, 'source': source, 'target': target, 'pins': {
        'flutter': {'version': '3.47.4', 'archive': FLUTTER[target][0], 'sha256': FLUTTER[target][1]},
        'dart': '3.13.3', 'wrong_node': {'version': '24.19.0', 'sha256': NODE[target][1]},
        'git': {'url': GIT_URL, 'ref': GIT_REF}, 'collection': '1.19.1'}}
    manifest.update({k: base + '/' + k for k in ('dart_sdk', 'wrong_node', 'pub_fixture',
                                                'git_fixture', 'flutter_sdk', 'flutter_fixture')})
    manifest['environment'] = {'ARCHWAY_PUB_GIT_FIXTURE': manifest['git_fixture'],
                               'ARCHWAY_FLUTTER_FIXTURE': manifest['flutter_fixture']}
    manifest['readiness'] = {name: {p: 'b' * 64 for p in
        ('pubspec.yaml', 'pubspec.lock', '.dart_tool/package_config.json')}
        for name in ('git-fixture', 'flutter-fixture')}
    path = directory / 'acceptance-fixtures.json'
    path.write_text(json.dumps(manifest))
    acceptance = directory / 'acceptance'
    acceptance.mkdir()
    suites = []
    names = ('plan_query', 'cli', 'catalogue_export', 'check', 'dart_check', 'physical_path',
             'alias_wire', 'alias_hop_recheck', 'alias_trace_gap', 'dart_resource', 'runtime',
             'runtime_request', 'runtime_preflight', 'native_asset', 'native_abi', 'native_fault',
             'package_provenance', 'dart_flutter')
    for name in names:
        command = [base + '/python', base + '/repo/test/' + name + '_process_smoke.py',
                   executed + '/bin/' + target + ('/archway.exe' if target == 'windows-x64' else '/archway')]
        args = {'check': [base + '/node'],
                'dart_check': [manifest['dart_sdk'], base + '/node', '--existing-installation'],
                'physical_path': [manifest['dart_sdk'], base + '/node'],
                'alias_wire': [base + '/node'], 'alias_hop_recheck': [base + '/node'],
                'alias_trace_gap': [base + '/node'], 'dart_resource': [manifest['dart_sdk']],
                'runtime': [base + '/node'],
                'runtime_request': [base + '/node', base + '/acceptance/runtime-request-coverage.json'],
                'runtime_preflight': [base + '/node', manifest['wrong_node'], manifest['dart_sdk']],
                'package_provenance': [base + '/repo', manifest['pub_fixture'], manifest['git_fixture'],
                                       base + '/acceptance/package-provenance'],
                'dart_flutter': [manifest['flutter_sdk'], manifest['flutter_fixture']]}
        command += args.get(name, [])
        proof = {'suite': name, 'command': command, 'exit_code': 0, 'timed_out': False,
                 'elapsed_seconds': 1.0, 'timeout_seconds': 600}
        for channel in ('stdout', 'stderr'):
            log = acceptance / (name + '.' + channel + '.log')
            log.write_bytes(b'SYNTHETIC UNIT FIXTURE\n' if channel == 'stdout' else b'')
            proof[channel] = log.name
            proof[channel + '_sha256'] = hashlib.sha256(log.read_bytes()).hexdigest()
        (acceptance / (name + '.json')).write_text(json.dumps(proof))
        suites.append(proof)
    return {'source_root': base + '/repo',
            'node': ['v24.21.0', {'linux-x64': 'linux', 'macos-arm64': 'darwin', 'windows-x64': 'win32'}[target],
                     'arm64' if target == 'macos-arm64' else 'x64'],
            'relocation': {'extracted': base + '/extracted installation', 'executed': executed,
                           'original_removed': True},
            'acceptance': {'source': source, 'source_root': base + '/repo', 'python': base + '/python',
                           'node_path': base + '/node', 'output_root': base + '/acceptance', 'fixtures': {
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'manifest': manifest}, 'suites': suites}}


def npm_fixture(route):
    errors = [('aliased-helper', 2, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
              ('corrupt-helper', 2, 'TYPESCRIPT_HELPER_FAILED'),
              ('missing-compiler', 2, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
              ('aliased-compiler', 2, 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
              ('corrupt-compiler', 2, 'TYPESCRIPT_LOAD_FAILED')]
    errors += [(n, 126, 'launcher-prelaunch') for n in (
        'missing-payload', 'aliased-payload', 'corrupt-payload',
        'missing-manifest', 'aliased-manifest', 'corrupt-manifest')]
    assets = [{'case': n, 'exit': c, 'error': e} for n, c, e in errors]
    assets.append({'case': 'restored-payload-help', 'exit': 0})
    corpus = ({'applicable': True,
               'selected_path': 'node_modules/archway-architecture-cli/assets/typescript/helper.cjs',
               'cases': [{'case': 'selected-installed-corpus', 'exit': 2, 'selected_present': True, 'observed_files': 3},
                         {'case': 'excluded-installed-corpus', 'exit': 0, 'selected_present': False, 'observed_files': 2}]}
              if route == 'local' else
              {'applicable': False, 'reason': 'installation-outside-inspected-root', 'cases': []})
    return {'asset_controls': assets, 'corpus_control': corpus}


def pub_fixture(directory, target):
    # Public shapes come from committed contract examples, never captured runs.
    # Route cases follow contracts/compatibility/delivery.md and tool/ci/README.md.
    cases = [
        ('init', ['init', '--template', 'mixed'], False, 'init-created', None),
        ('validate', ['validate'], False, 'validate-ok', None),
        ('node', ['node'], False, 'node-catalogue', None),
        ('export-stdout', ['export', '--format', 'mermaid'], False, 'export-ok', None),
        ('export-file', ['export', '--format', 'mermaid', '--out', 'diagram.mmd'], False, 'export-ok', None),
        ('typescript', ['check'], True, 'check-empty', None),
        ('missing-node', ['check'], False, 'check-tool-error', 'NODE_UNAVAILABLE'),
        ('missing-helper', ['check'], True, 'check-tool-error', 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
        ('aliased-helper', ['check'], True, 'check-tool-error', 'TYPESCRIPT_ASSETS_UNAVAILABLE'),
        ('restored-typescript', ['check'], True, 'check-empty', None),
        ('missing-bridge-validate', ['validate'], False, 'validate-ok', None),
        ('missing-bridge-export', ['export', '--format', 'mermaid', '--out', 'blocked.mmd'],
         False, 'export-error', 'EXPORT_WRITE_FAILED'),
        ('missing-bridge-init', ['init', '--template', 'mixed'], False, 'init-root-access-error', 'INIT_UNAVAILABLE'),
    ]
    analysis = directory / 'analysis'
    analysis.mkdir()
    receipts = []
    for name, arguments, node_available, example, error in cases:
        value = json.loads((ROOT / 'contracts/json/fixtures' / (example + '.json')).read_text())
        value['tool_versions']['archway'] = 'synthetic-unit-fixture'
        value['resolved_root'] = '/synthetic-unit-fixture'
        if error:
            diagnostics = value['payload']['tool_errors'] if arguments[0] == 'check' else value['diagnostics']
            diagnostics[0].update(code=error, message='Synthetic unit fixture only')
            if arguments[0] == 'check':
                value['status'] = 'incomplete'
                value['diagnostics'] = diagnostics
        export = arguments[0] == 'export'
        if export and '--out' in arguments:
            value['payload']['out'] = arguments[-1]
        data = (json.dumps(value) + '\n').encode()
        stdout = b'%% Synthetic unit fixture only\nflowchart LR\n' if name == 'export-stdout' else b''
        streams = {'stdout': stdout if export else data, 'stderr': data if export else b''}
        receipt = {'case': name, 'arguments': arguments, 'exit': value['exit_code'],
                   'node_available': node_available, 'error': error}
        for channel, contents in streams.items():
            (analysis / (name + '.' + channel + '.log')).write_bytes(contents)
            receipt[channel + '_sha256'] = hashlib.sha256(contents).hexdigest()
        receipts.append(receipt)
    return {'analysis': {'node': {'version': 'v24.21.0',
        'platform': {'linux-x64': 'linux', 'macos-arm64': 'darwin', 'windows-x64': 'win32'}[target],
        'arch': 'arm64' if target == 'macos-arm64' else 'x64'}, 'cases': receipts}}
