"""Installed pub snapshot policy, compiler and owned-asset acceptance."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from jsonschema import Draft202012Validator
from npm_local_install_probe import command
from npm_local_analysis import snapshot



def diagnose_windows_exit(launcher, arguments, cwd, environment, output):
    """Observe the same read-only check at the VM and cmd boundaries."""
    dart = shutil.which('dart', path=environment['PATH'])
    if dart is None:
        raise ValueError('Diagnostic pinned Dart is missing from runtime PATH')
    snapshot_path = Path(environment['PUB_CACHE']) / (
        'global_packages/archway/bin/archway.dart-3.13.3.snapshot')
    original = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in [launcher, snapshot_path]}
    (output / 'exit-mismatch-launcher.log').write_bytes(launcher.read_bytes())
    direct = [dart, str(snapshot_path), *arguments]
    observations = {'dart': dart, 'original_sha256': original, 'routes': []}
    for label, invocation in [('direct-snapshot', direct),
                              ('cmd-snapshot', command(direct))]:
        try:
            result = subprocess.run(invocation, cwd=cwd, env=environment,
                                    capture_output=True, timeout=30)
            (output / (label + '.stdout.log')).write_bytes(result.stdout)
            (output / (label + '.stderr.log')).write_bytes(result.stderr)
            observations['routes'].append({'route': label, 'command': invocation,
                'exit': result.returncode, 'stdout_sha256': hashlib.sha256(result.stdout).hexdigest(),
                'stderr_sha256': hashlib.sha256(result.stderr).hexdigest()})
        except (OSError, subprocess.SubprocessError) as error:
            observations['routes'].append({'route': label, 'error': str(error)})
    observations['unchanged'] = all(
        hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest
        for path, digest in original.items())
    (output / 'exit-mismatch.log').write_text(json.dumps(observations, indent=2) + '\n', encoding='utf-8')
    print('WINDOWS_PUB_EXIT_DIAGNOSTIC=' + json.dumps(observations), flush=True)


def exercise(launcher, installed, node, target, output, environment):
    output.mkdir()
    root, cwd = output / 'project café', output / 'foreign cwd café'
    root.mkdir()
    cwd.mkdir()
    schemas = Path(__file__).resolve().parents[2] / 'contracts/json'
    public = Draft202012Validator(json.loads((schemas / 'public-result.schema.json').read_text()))
    export = Draft202012Validator(json.loads((schemas / 'export-diagnostics.schema.json').read_text()))
    assert shutil.which('node', path=environment['PATH']) is None
    node_env = {**environment, 'PATH': str(node.parent) + os.pathsep + environment['PATH']}
    assert Path(shutil.which('node', path=node_env['PATH'])).resolve() == node.resolve()
    version = subprocess.run([str(node), '-p',
        'JSON.stringify({version:process.version,platform:process.platform,arch:process.arch})'],
        env=node_env, capture_output=True, timeout=15, check=True)
    actual = json.loads(version.stdout)
    assert actual == {'version': 'v24.21.0', 'platform': {
        'linux-x64': 'linux', 'macos-arm64': 'darwin', 'windows-x64': 'win32'}[target],
        'arch': 'arm64' if target == 'macos-arm64' else 'x64'}, 'Wrong pinned Node host/version'
    cases = []
    original = snapshot(installed)

    def invoke(name, args, code=0, with_node=False, error=None):
        result = subprocess.run(command([str(launcher), '--root', str(root), *args]),
            cwd=cwd, env=node_env if with_node else environment,
            capture_output=True, timeout=60)
        (output / (name + '.stdout.log')).write_bytes(result.stdout)
        (output / (name + '.stderr.log')).write_bytes(result.stderr)
        if os.name == 'nt' and name == 'missing-node' and result.returncode != code:
            try:
                diagnose_windows_exit(launcher, ['--root', str(root), *args], cwd,
                                      environment, output)
            except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
                print(f'WINDOWS_PUB_EXIT_DIAGNOSTIC_FAILED={error}', flush=True)
        assert result.returncode == code, (name, result.returncode, result.stdout, result.stderr)
        assert not list(cwd.iterdir()), 'Foreign cwd changed'
        value = None
        if args[0] == 'export':
            if result.stderr:
                value = json.loads(result.stderr)
                export.validate(value)
                assert value['exit_code'] == code
            else:
                assert code == 0, 'Failed export omitted diagnostics'
        else:
            assert result.stderr == b''
            assert result.stdout.endswith(b'\n') and result.stdout.count(b'\n') == 1
            value = json.loads(result.stdout)
            public.validate(value)
            assert value['exit_code'] == code and value['command'] == args[0]
        if error:
            errors = value['payload']['tool_errors'] if args[0] == 'check' else value['diagnostics']
            assert [item['code'] for item in errors] == [error], (name, value)
        cases.append({'case': name, 'arguments': args, 'exit': code,
            'node_available': with_node, 'error': error,
            'stdout_sha256': hashlib.sha256(result.stdout).hexdigest(),
            'stderr_sha256': hashlib.sha256(result.stderr).hexdigest()})
        return value, result.stdout

    invoke('init', ['init', '--template', 'mixed'])
    invoke('validate', ['validate'])
    invoke('node', ['node'])
    _, diagram = invoke('export-stdout', ['export', '--format', 'mermaid'])
    assert diagram.endswith(b'flowchart LR\n')
    invoke('export-file', ['export', '--format', 'mermaid', '--out', 'diagram.mmd'])
    assert (root / 'diagram.mmd').read_bytes() == diagram
    (root / 'src').mkdir()
    (root / 'src/main.ts').write_text('export const value = 1;\n', encoding='utf-8')
    (root / 'tsconfig.json').write_text('{"include":["src/**/*.ts"]}', encoding='utf-8')
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]
''', encoding='utf-8')
    marker = root / 'project-decoy-executed'
    for relative in ['assets/typescript/helper.cjs', 'node_modules/typescript/lib/typescript.js']:
        decoy = root / relative
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) +
                         ", 'executed');throw Error('decoy');", encoding='utf-8')

    def check(name, code=0, with_node=True, error=None):
        before = snapshot(root)
        value, _ = invoke(name, ['check'], code, with_node, error)
        assert snapshot(root) == before and not marker.exists(), 'Project changed or decoy executed'
        assert value['payload']['analysis_complete'] is (code == 0)
        if not code:
            assert value['tool_versions']['typescript'] == '5.9.3'
            assert value['payload']['observed'] == {'files': 1, 'analyzed_files': 1, 'edges': 0}
            assert value['payload']['tool_errors'] == []

    check('typescript')
    check('missing-node', 2, False, 'NODE_UNAVAILABLE')
    helper = installed / 'assets/typescript/helper.cjs'
    saved = helper.with_name('saved-helper.cjs')
    assert not saved.exists()
    helper.rename(saved)
    try:
        check('missing-helper', 2, True, 'TYPESCRIPT_ASSETS_UNAVAILABLE')
        # No platform skip: failure to create a real alias leaves acceptance unproven.
        helper.symlink_to(root / 'assets/typescript/helper.cjs')
        try:
            check('aliased-helper', 2, True, 'TYPESCRIPT_ASSETS_UNAVAILABLE')
        finally:
            helper.unlink()
    finally:
        saved.rename(helper)
    assert snapshot(installed) == original, 'Installed helper was not restored'
    check('restored-typescript')
    bridge = installed / 'native' / target / {
        'linux-x64': 'libarchway_io.so', 'macos-arm64': 'libarchway_io.dylib',
        'windows-x64': 'archway_io.dll'}[target]
    saved = bridge.with_suffix(bridge.suffix + '.saved')
    assert not saved.exists()
    bridge.rename(saved)
    try:
        invoke('missing-bridge-validate', ['validate'])
        invoke('missing-bridge-export', ['export', '--format', 'mermaid', '--out', 'blocked.mmd'],
               2, error='EXPORT_WRITE_FAILED')
        assert not (root / 'blocked.mmd').exists()
        (root / 'architecture.yaml').unlink()
        (root / 'ARCHITECTURE.md').unlink()
        invoke('missing-bridge-init', ['init', '--template', 'mixed'], 2, error='INIT_UNAVAILABLE')
    finally:
        saved.rename(bridge)
    assert snapshot(installed) == original, 'Installed bridge was not restored'
    return {'node': actual, 'cases': cases}
