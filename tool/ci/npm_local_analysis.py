"""Bounded installed TypeScript check/exit controls, not full schema certification."""
import hashlib
import json


def assert_result(result, expected_exit, expected_status):
    assert result.returncode == expected_exit, 'Actual exit differs from expected exit'
    assert result.stderr == b'', 'Unexpected stderr'
    assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1, 'Expected one JSON line'
    assert not result.stdout.startswith(b'\xef\xbb\xbf'), 'Unexpected JSON BOM'
    value = json.loads(result.stdout.decode('utf-8'))
    assert value['schema_version'] == 1 and value['command'] == 'check'
    assert value['exit_code'] == expected_exit, 'Envelope exit differs from process exit'
    assert value['status'] == expected_status, 'Unexpected check status'
    return value


def snapshot(root):
    result = {}
    for path in root.rglob('*'):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = ('link', str(path.readlink()))
        elif path.is_dir():
            result[name] = ('directory',)
        else:
            with path.open('rb') as stream:
                result[name] = ('file', hashlib.file_digest(stream, 'sha256').hexdigest())
    return result


def exercise(shim, root, cwd, installed, environment, run, *, installation_root=None, read_only=False):
    # The existing check_process_smoke two-node fixture, with its import toggled.
    installation_root = root if installation_root is None else installation_root
    assert installation_root.resolve() == installation_root
    assert installed.is_relative_to(installation_root)
    assert installed.resolve().is_relative_to(installation_root)

    source = root / 'src/app/main.ts'
    source.parent.mkdir(parents=True, exist_ok=True)
    core = root / 'src/core/private.ts'
    core.parent.mkdir(parents=True, exist_ok=True)
    clean = 'export const value = 1;\n'
    source.write_text(clean, encoding='utf-8')
    core.write_text(clean, encoding='utf-8')
    (root / 'tsconfig.json').write_text(
        '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}',
        encoding='utf-8')
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''', encoding='utf-8')
    marker = root / 'project-decoy-executed'
    for relative in ['assets/typescript/helper.cjs', 'node_modules/typescript/lib/typescript.js']:
        decoy = root / relative
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) +
                         ", 'executed');throw Error('decoy');", encoding='utf-8')
    cases = []

    def invoke(name, code, status, extra=()):
        before = snapshot(root)
        foreign = snapshot(cwd)
        installation = snapshot(installation_root) if installation_root != root else None
        result = run([str(shim), '--root', str(root), 'check', *extra], cwd, environment,
                     expected_exit=code)
        assert not marker.exists(), 'Project decoy executed'
        assert snapshot(root) == before, 'Check unexpectedly changed project files'
        assert snapshot(cwd) == foreign == {}, 'Check unexpectedly changed foreign cwd'
        if installation is not None:
            assert snapshot(installation_root) == installation, 'Check unexpectedly changed installation'
        value = assert_result(result, code, status)
        payload = value['payload']
        if code == 64:
            assert payload is None, 'Usage error must have null payload'
        else:
            assert payload['policy_valid'] is True
            assert payload['analysis_complete'] is (code != 2), 'Wrong analysis completeness'
            if code == 2:
                assert [error['code'] for error in payload['tool_errors']] == ['TYPESCRIPT_ASSETS_UNAVAILABLE']
            else:
                assert value['tool_versions']['typescript'] == '5.9.3'
                assert payload['tool_errors'] == [] and payload['unknowns'] == []
                assert payload['observed'] == {'files': 2, 'analyzed_files': 2, 'edges': code}
                assert [violation['code'] for violation in payload['violations']] == (
                    ['DEPENDENCY_NOT_ALLOWED'] if code == 1 else [])
        cases.append({'case': name, 'command': 'check', 'exit': code, 'status': status,
                      'analysis_complete': None if payload is None else payload['analysis_complete']})

    invoke('clean', 0, 'ok')
    source.write_text("import {value} from '../core/private';\n", encoding='utf-8')
    invoke('dependency-violation', 1, 'negative')
    invoke('unsupported-option', 64, 'usage_error', ['--unsupported'])
    source.write_text(clean, encoding='utf-8')
    if read_only:
        return cases
    helper = installed / 'assets/typescript/helper.cjs'
    original = snapshot(helper.parent)
    saved = helper.with_suffix('.cjs.saved')
    assert not saved.exists()
    helper.rename(saved)
    try:
        invoke('missing-owned-helper', 2, 'incomplete')
    finally:
        saved.rename(helper)
    assert snapshot(helper.parent) == original, 'Owned helper was not restored exactly'
    invoke('restored-clean', 0, 'ok')
    return cases
