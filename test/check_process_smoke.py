"""AOT check transport, schemas and helper faults on Linux, macOS and Windows.

Pass the compiled executable and pinned Node binary. Assets are deployed beside
an isolated executable and invoked from another cwd. Not release certification.
"""
import json
import base64
import hashlib
import os
from pathlib import Path
import shutil
from installation_staging import stage_installation
from inventory_fixture import inventory_kind
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator


def windows_inventory_attributes(folder, entries):
    """Observe the native attribute API used by pinned Dart."""
    import ctypes
    from long_path_fixture import fixture_path

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    attributes = kernel.GetFileAttributesExW
    attributes.argtypes = [ctypes.c_wchar_p, ctypes.c_int, ctypes.c_void_p]
    attributes.restype = ctypes.c_int
    results = []
    for name, kind in entries:
        # WIN32_FILE_ATTRIBUTE_DATA consists of nine 32-bit words. Match Dart's
        # extended absolute pathname, without following or opening file data.
        data = (ctypes.c_uint32 * 9)()
        path = str(fixture_path(folder / name, windows=True))
        succeeded = bool(attributes(path, 0, data))
        error = None if succeeded else ctypes.get_last_error()
        results.append({'name': name, 'listed_kind': kind,
                        'attributes': data[0] if succeeded else None,
                        'win32_error': error})
    return results


repository = Path(__file__).resolve().parents[1]
executable = Path(sys.argv[1]).resolve()
node = Path(sys.argv[2]).resolve()
schema = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
count = 0

with tempfile.TemporaryDirectory(prefix='archway-check-process-') as temporary:
    # Direct helper requests, unlike the CLI, require a physical root URI.
    base = Path(temporary).resolve()
    install = base / 'project with spaces' / 'installation café'
    install.mkdir(parents=True)
    binary = stage_installation(executable, install)
    root = base / 'project with spaces'
    (root / 'src/app').mkdir(parents=True)
    (root / 'src/core').mkdir(parents=True)
    (root / 'src/app/main.ts').write_text("import {value} from '../core/private';\n")
    (root / 'src/core/private.ts').write_text('export const value = 1;\n')
    (root / 'tsconfig.json').write_text('{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}')
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''')
    def invoke(expected, env=None):
        global count
        result = subprocess.run([str(binary), '--root', str(root), 'check'],
            cwd=base, env={**os.environ, 'PATH': str(node.parent), **(env or {})},
            capture_output=True, timeout=15)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == b'', result.stderr
        assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1
        value = json.loads(result.stdout.decode('utf-8'))
        schema.validate(value)
        assert value['exit_code'] == result.returncode
        count += 1
        return value

    marker = root / 'project-decoy-executed'
    for relative in ['assets/typescript/helper.cjs', 'node_modules/typescript/lib/typescript.js']:
        decoy = root / relative
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) + ", 'executed');throw Error('decoy');")
    result = invoke(1)
    assert not marker.exists()
    assert result['payload']['analysis_complete']
    assert result['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
    assert result['tool_versions']['typescript'] == '5.9.3'
    original_payload = result['payload']
    # Later input-change cases intentionally begin without project packages.
    shutil.rmtree(root / 'node_modules')
    shutil.rmtree(root / 'assets')
    assert invoke(1, {'NODE_OPTIONS':'--require=/no-project-loader.cjs', 'NODE_PATH':str(root)})['payload']['analysis_complete']

    helper = install / 'assets/typescript/helper.cjs'
    marker = root / 'executed-project-code'
    project_helper = root / 'project-helper.cjs'
    project_helper.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) + ", 'executed');process.stdout.write('{}');")
    for asset in [helper, helper.with_name('framing.cjs'), helper.with_name('trace.cjs'),
                  helper.parent / 'vendor/typescript/lib/typescript.js']:
        original_asset = asset.read_bytes()
        asset.unlink()
        asset.symlink_to(project_helper)
        result = invoke(2)
        assert not marker.exists(), 'A symlinked asset executed inspected-project code'
        assert result['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'
        asset.unlink()
        asset.write_bytes(original_asset)
    compiler_package = helper.parent / 'vendor/typescript'
    backup_package = compiler_package.with_name('typescript-backup')
    compiler_package.rename(backup_package)
    compiler_package.symlink_to(root, target_is_directory=True)
    assert invoke(2)['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'
    compiler_package.unlink()
    backup_package.rename(compiler_package)
    protocol = json.loads((repository / 'contracts/helper/request.schema.json').read_text())['properties']['protocol_version']['const']
    request = {'protocol_version':protocol, 'request_id':'check:web', 'project_id':'web',
        'root_uri':root.as_uri(), 'config_path':'tsconfig.json',
        'expected_files':['src/app/main.ts','src/core/private.ts']}
    capture = subprocess.run([str(node), str(helper)], input=json.dumps(request).encode(),
        capture_output=True, env={k:v for k,v in os.environ.items() if not k.startswith('NODE_')})
    assert capture.returncode == 0 and capture.stderr == b'', (
        capture.returncode, capture.stdout, capture.stderr)
    captured = capture.stdout
    envelope = json.loads(captured)
    assert envelope['status'] == 'complete' and envelope['facts'], envelope
    def canned(raw, exit_code=0, before=""):
        helper.write_text("process.stdin.resume(); process.stdin.on('end',()=>{" + before + "process.stdout.write(Buffer.from('" +
            base64.b64encode(raw).decode() + "','base64'));process.exitCode=" + str(exit_code) + ";});")
    canned(b'\xef\xbb\xbf' + captured)
    result = invoke(2)
    assert result['payload']['facts']['edges'] == []
    assert result['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_HELPER_FAILED'

    # Each transport fault invalidates the whole project's otherwise valid facts.
    bad_frames = [captured + b'{}', captured + b' trailing', captured.rstrip()[:-1], b'\xff',
        captured.replace(b'"path":', b'"path":null,"p\\u0061th":', 1), captured.replace(b'"protocol_version":' + str(protocol).encode(), b'"protocol_version":' + str(protocol).encode() + b',"protocol_version":' + str(protocol).encode(), 1)]
    for raw in bad_frames:
        canned(raw)
        assert invoke(2)['payload']['facts']['edges'] == []
    for edit in [
        lambda e: e.update(extra=True),
        lambda e: e.update(protocol_version=protocol + 1),
        lambda e: e.update(project_id='other-project'),
        lambda e: e.pop('files'),
        lambda e: e['files'].reverse(),
        lambda e: e['facts'][0]['source_range']['start'].update(extra=1),
        lambda e: e['inputs'].append(e['inputs'][0]),
        lambda e: e.update(status='failed', tool_errors=[]),
        lambda e: e['files'][0].update(coverage='partial'),
        lambda e: e.update(request_id='another-request'),
        lambda e: e['facts'][0]['source_range']['end'].update(line=99),
        lambda e: e['facts'][0].update(input_ids=['missing-evidence']),
        lambda e: e['files'][0].update(membership='nonmember', coverage='not_applicable', input_id=None),
    ]:
        changed = json.loads(captured)
        edit(changed)
        canned(json.dumps(changed).encode())
        assert invoke(2)['payload']['facts']['edges'] == []
    changed = json.loads(captured)
    target_uri = (root / 'src/core/bad*.ts').as_uri().replace('%2A', '*')
    changed['inputs'].append({'id':'bad-target','kind':'file','observed_uri':target_uri,'canonical_uri':target_uri,'sha256':'a'*64, 'symlink_hops': []})
    changed['facts'][0]['resolution'].update(path='src/core/bad*.ts',canonical_file_uri=target_uri)
    changed['facts'][0]['input_ids'].append('bad-target')
    canned(json.dumps(changed).encode())
    assert invoke(2)['payload']['facts']['edges'] == []
    for via in [(root / 'missing.ts').as_uri(), envelope['facts'][0]['resolution']['canonical_file_uri']]:
        changed = json.loads(captured)
        changed['facts'][0]['resolution']['via_path'] = via
        canned(json.dumps(changed).encode())
        assert invoke(2)['payload']['facts']['edges'] == []
    # These deliberately malformed root observations remain negative cases.
    for kind in ['absent', 'file']:
        changed = json.loads(captured)
        observation = {'symlink_hops': [], 'id':'root-input','kind':kind,'observed_uri':'file:///','canonical_uri':None if kind == 'absent' else 'file:///'}
        if kind == 'file': observation['sha256'] = 'a'*64
        changed['inputs'].append(observation)
        canned(json.dumps(changed).encode())
        assert invoke(2)['payload']['facts']['edges'] == []
    def inventory_entries(folder):
        with os.scandir(folder) as entries:
            return sorted([[entry.name, inventory_kind(entry)] for entry in entries])

    def inventory_hash(entries):
        return hashlib.sha256(json.dumps(
            entries, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()

    if os.name == 'nt':
        # Controlled native proof before testing the machine's uncontrolled root.
        # Neither Python mocks nor Linux passes establish this Windows behavior.
        junction_inventory = base / 'junction-inventory'
        junction_inventory.mkdir()
        target = junction_inventory / 'target'
        target.mkdir()
        junction = junction_inventory / 'alias'
        create = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J',
                                 str(junction), str(target)], capture_output=True)
        assert create.returncode == 0, (create.stdout, create.stderr)
        metadata = junction.lstat()
        assert metadata.st_file_attributes & 0x400
        assert metadata.st_reparse_tag == 0xA0000003, metadata
        assert not junction.is_symlink(), 'The control must be a junction, not a symlink'
        expected_entries = [['alias', 'symlink'], ['target', 'directory']]
        assert inventory_entries(junction_inventory) == expected_entries
        inventory_uri = junction_inventory.as_uri()
        for entries, expected_exit in [
            ([['alias', 'directory'], ['target', 'directory']], 2),
            (expected_entries, 1),
        ]:
            changed = json.loads(captured)
            digest = inventory_hash(entries)
            changed['inputs'].append({
                'id': 'junction-inventory', 'kind': 'directory', 'symlink_hops': [],
                'observed_uri': inventory_uri, 'canonical_uri': inventory_uri,
                'sha256': digest,
            })
            canned(json.dumps(changed).encode())
            result = invoke(expected_exit)
            identity = result['payload']['input_identity']
            assert identity['rechecked']
            if expected_exit == 2:
                assert identity['changed_inputs'] == [
                    {'kind': 'external', 'canonical_file_uri': inventory_uri}]
            else:
                assert identity['changed_inputs'] == []
                assert {'kind': 'inventory', 'location': {
                    'kind': 'external', 'canonical_file_uri': inventory_uri},
                    'presence': 'present', 'hash': 'sha256:' + digest} in identity['inputs']
        junction.rmdir()
        target.rmdir()
        junction_inventory.rmdir()
        print('Native junction inventory: directory hash rejected; symlink hash accepted.')

    changed = json.loads(captured)
    # The parent and inspected process may run on different Windows drives.
    filesystem_root = Path(root.anchor)
    filesystem_root_uri = filesystem_root.as_uri()
    root_entries = inventory_entries(filesystem_root)
    root_hash = inventory_hash(root_entries)
    changed['inputs'].append({
        'id': 'filesystem-root', 'kind': 'directory',
        'symlink_hops': [],
        'observed_uri': filesystem_root_uri, 'canonical_uri': filesystem_root_uri, 'sha256': root_hash,
    })
    canned(json.dumps(changed).encode())
    # Freeze the oracle before invoking Archway. Host-root entries may be
    # enumerable while their per-path attribute query is sharing-blocked.
    attributes_before = windows_inventory_attributes(filesystem_root, root_entries) if os.name == 'nt' else []
    blocked_before = [entry for entry in attributes_before if entry['win32_error'] is not None]
    assert all(entry['win32_error'] == 32 for entry in blocked_before), blocked_before
    expected_exit = 2 if blocked_before else 1
    try:
        result = invoke(expected_exit)
        assert inventory_entries(filesystem_root) == root_entries
        if os.name == 'nt':
            attributes_after = windows_inventory_attributes(filesystem_root, root_entries)
            blocked_after = [entry for entry in attributes_after if entry['win32_error'] is not None]
            assert blocked_after == blocked_before, (blocked_before, blocked_after)
    except AssertionError:
        # A second independent scan exposes mutation; it is not the CLI's digest.
        diagnostic = {'root_inventory': filesystem_root_uri,
                      'expected_entries': root_entries, 'expected_hash': root_hash}
        try:
            after_entries = inventory_entries(filesystem_root)
            diagnostic.update(after_entries=after_entries,
                              after_hash=inventory_hash(after_entries))
        except OSError as error:
            diagnostic['after_scan_error'] = str(error)
        if os.name == 'nt':
            try:
                diagnostic['windows_attributes'] = windows_inventory_attributes(
                    filesystem_root, root_entries)
            except Exception as error:
                diagnostic['windows_attribute_error'] = str(error)
        print(json.dumps(diagnostic), file=sys.stderr)
        raise
    payload = result['payload']
    identity = payload['input_identity']
    assert {
        'kind': 'inventory',
        'location': {'kind': 'external', 'canonical_file_uri': filesystem_root_uri},
        'presence': 'present', 'hash': 'sha256:' + root_hash,
    } in identity['inputs']
    assert payload['facts'] == original_payload['facts']
    assert payload['violations'] == original_payload['violations']
    assert payload['unknowns'] == [] and identity['changed_inputs'] == []
    if blocked_before:
        assert result['status'] == 'incomplete' and not payload['analysis_complete']
        assert identity['rechecked'] is False
        message = "FileSystemException: Directory entry is unrepresentable or changed, path = '" + str(filesystem_root) + "'"
        assert [(error['code'], error['message']) for error in payload['tool_errors']] == [
            ('INPUT_RECHECK_FAILED', message)]
        print('Filesystem-root positive proof unavailable: native attribute access blocked ' +
              json.dumps(blocked_before) + '; fail-closed root recheck verified.', flush=True)
    else:
        assert result['status'] == 'negative' and payload['analysis_complete']
        assert identity['rechecked'] is True and payload['tool_errors'] == []
        print('Filesystem-root positive inventory proof passed.', flush=True)
    canned(captured, exit_code=1)
    assert invoke(2)['payload']['facts']['edges'] == []
    failed = json.loads(captured)
    failed.update(status='failed', tool_errors=[{'code':'PROJECT_FAILURE','message':'Injected project failure','path':None,'source_range':None}])
    canned(json.dumps(failed).encode())
    result = invoke(2)
    assert result['payload']['facts']['edges'][0]['resolution']['kind'] == 'local'
    assert result['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'

    original_config = (root / 'tsconfig.json').read_text()
    config_js = "require('node:fs').appendFileSync(" + json.dumps(str(root / 'tsconfig.json')) + ", '\\n');"
    canned(captured, before=config_js)
    result = invoke(2)
    assert {'kind':'repository','path':'tsconfig.json'} in result['payload']['input_identity']['changed_inputs']
    assert result['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED'
    (root / 'tsconfig.json').write_text(original_config)
    mkdir_js = "require('node:fs').mkdirSync(" + json.dumps(str(root / 'node_modules')) + ");"
    canned(captured, before=mkdir_js)
    result = invoke(2)
    assert {'kind':'repository','path':'node_modules'} in result['payload']['input_identity']['changed_inputs']
    (root / 'node_modules').rmdir()
    new_source = root / 'src/app/new.ts'
    create_js = "require('node:fs').writeFileSync(" + json.dumps(str(new_source)) + ", 'export {};');"
    canned(captured, before=create_js)
    result = invoke(2)
    assert {'kind':'repository','path':'src/app'} in result['payload']['input_identity']['changed_inputs']
    new_source.unlink()

    canned(captured, before="process.stderr.write(Buffer.alloc(256*1024, 120));")
    assert invoke(1)['payload']['analysis_complete']
    canned(captured, before="process.stderr.write(Buffer.alloc(256*1024+1, 120));")
    assert invoke(2)['payload']['facts']['edges'] == []
    canned(captured, before="process.stdout.write(Buffer.alloc(64*1024*1024+1, 32));")
    assert invoke(2)['payload']['facts']['edges'] == []

    # A controlled filesystem-boundary race: the first stat result differs
    # from the immediately following observation of that same target.
    real_helper = helper.with_name('real-helper.cjs')
    real_helper.write_bytes((repository / 'assets/typescript/helper.cjs').read_bytes())
    helper.write_text("const fs=require('node:fs'), original=fs.statSync;let first=true;" +
        "fs.statSync=function(file,...args){if(first && String(file)===" + json.dumps(str(root / 'src/core/private.ts')) +
        "){first=false;return original(" + json.dumps(str(root / 'src/core')) +
        ",...args);}return original(file,...args);};require('./real-helper.cjs');")
    result = invoke(2)
    assert 'TYPESCRIPT_INPUT_TRACE_FAILED' in [d['code'] for d in result['payload']['tool_errors']]

    helper.write_bytes((repository / 'assets/typescript/helper.cjs').read_bytes())
    compiler = helper.parent / 'vendor/typescript/lib/typescript.js'
    original_compiler = compiler.read_text()
    assert 'var version = "5.9.3";' in original_compiler
    compiler.write_text(original_compiler.replace('var version = "5.9.3";', 'var version = "0.0.0";', 1))
    result = invoke(2)
    assert result['tool_versions']['typescript'] is None
    assert result['payload']['facts']['edges'] == []
    assert result['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_VERSION_MISMATCH'
    compiler.unlink()
    result = invoke(2)
    assert result['tool_versions']['typescript'] is None
    assert result['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'

print(f'{count} real check process/schema checks passed.')
