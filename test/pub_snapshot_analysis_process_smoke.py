"""Real isolated pub Git activation and pub-generated snapshot, without publication.

Arguments: pinned Dart, pinned Node, prepared PUB_CACHE. This is local Git route
layout evidence, not hosted-registry or publishable-file-set acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urljoin, urlparse, unquote
from jsonschema import Draft202012Validator

repository = Path(__file__).resolve().parents[1]
public = Draft202012Validator(json.loads((repository / 'contracts/json/public-result.schema.json').read_text()))
export = Draft202012Validator(json.loads((repository / 'contracts/json/export-diagnostics.schema.json').read_text()))
dart, node, prepared_cache = [Path(value).resolve() for value in sys.argv[1:4]]
count = 0
with tempfile.TemporaryDirectory(prefix='archway-pub-layout-') as temporary:
    base = Path(temporary).resolve()
    source = base / 'prepared source café'
    prepared_source = Path(sys.argv[4]).resolve() if len(sys.argv) > 4 else None
    if prepared_source:
        shutil.copytree(prepared_source, source)
        assets = source / 'assets/typescript'
    else:
        source.mkdir()
        for directory in ['bin', 'lib']:
            shutil.copytree(repository / directory, source / directory)
        assets = source / 'assets/typescript'
        assets.mkdir(parents=True)
        for pattern in ['*.cjs', '*.json', '*.md']:
            for file in (repository / 'assets/typescript').glob(pattern):
                shutil.copy2(file, assets / file.name)
        shutil.copytree(repository / 'assets/typescript/vendor', assets / 'vendor')
        shutil.copytree(repository / 'assets/typescript/licenses', assets / 'licenses')
        shutil.copytree(repository / 'native/linux-x64', source / 'native/linux-x64')
        for name in ['pubspec.yaml', 'pubspec.lock']:
            shutil.copy2(repository / name, source / name)
    staged_hashes = {file.relative_to(source).as_posix(): hashlib.sha256(file.read_bytes()).hexdigest()
                     for file in source.rglob('*') if file.is_file()}
    subprocess.run(['git', 'init', '-q', str(source)], check=True)
    subprocess.run(['git', '-C', str(source), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(source), '-c', 'user.name=Installation fixture',
                    '-c', 'user.email=fixture@example.invalid', 'commit', '-qm',
                    'Prepared local installation fixture'], check=True)
    commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    cache = base / 'isolated cache café'
    for directory in ['hosted', 'hosted-hashes']:
        shutil.copytree(prepared_cache / directory, cache / directory)
    home = base / 'home'
    home.mkdir()
    environment = {**os.environ, 'HOME': str(home), 'PUB_CACHE': str(cache),
                   'DASH__SUPPRESS_ANALYTICS': 'true',
                   'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.hooksPath',
                   'GIT_CONFIG_VALUE_0': '/dev/null'}
    activation = subprocess.run([str(dart), '--suppress-analytics', 'pub', 'global',
                                 'activate', '--source', 'git', source.as_uri()],
                                env=environment, capture_output=True, text=True, timeout=240)
    assert activation.returncode == 0, (activation.stdout, activation.stderr)
    snapshots = list((cache / 'global_packages/archway').rglob('*.snapshot'))
    assert snapshots, 'Activation did not produce a real executable snapshot'
    launcher = cache / 'bin/archway'
    assert launcher.is_file()
    config = cache / 'global_packages/archway/.dart_tool/package_config.json'
    package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'archway')
    installed = Path(unquote(urlparse(urljoin(config.as_uri(), package['rootUri'])).path))
    assert installed.is_relative_to(cache / 'git'), installed
    for relative, digest in staged_hashes.items():
        assert hashlib.sha256((installed / relative).read_bytes()).hexdigest() == digest, relative
    # Installation explicitly owns repair; ordinary invocations never patch files.
    generated_launcher = launcher.read_bytes()
    setup_command = [str(dart), 'pub', 'global', 'run', 'archway:setup']
    def setup():
        result = subprocess.run(setup_command, env=environment, capture_output=True,
                                text=True, timeout=90)
        assert result.returncode == 0, (result.stdout, result.stderr)
    setup()
    repaired_launcher = launcher.read_bytes()
    setup()
    assert launcher.read_bytes() == repaired_launcher
    reactivation = subprocess.run([str(dart), 'pub', 'global', 'activate',
        '--source', 'git', source.as_uri()], env=environment, capture_output=True,
        text=True, timeout=240)
    assert reactivation.returncode == 0, reactivation.stderr
    assert launcher.read_bytes() == generated_launcher
    setup()
    assert launcher.read_bytes() == repaired_launcher
    shutil.rmtree(source)
    # Keep the entrypoint present: pub checks existence even when using a snapshot.
    entrypoint = installed / 'bin/archway.dart'
    entrypoint.write_text('THIS IS INTENTIONALLY INVALID DART !!!\n')
    control = subprocess.run([str(dart), str(entrypoint), '--version'],
        env=environment, capture_output=True, text=True, timeout=45)
    assert control.returncode != 0, 'Poisoned direct source unexpectedly ran'
    control = subprocess.run([str(dart), 'pub', 'global', 'run',
        'archway:archway', '--version'], env=environment, capture_output=True,
        text=True, timeout=45)
    assert control.returncode == 0 and not control.stderr, (control.stdout, control.stderr)

    cwd = base / 'foreign cwd café'
    cwd.mkdir()
    root = base / 'project with spaces'
    root.mkdir()
    shell_bin = base / 'launcher runtime'
    shell_bin.mkdir()
    (shell_bin / 'sh').symlink_to(Path('/bin/sh').resolve())

    def invoke(args, expected, with_node=False):
        global count
        path = str(shell_bin) + os.pathsep + str(dart.parent) + (os.pathsep + str(node.parent) if with_node else '')
        result = subprocess.run([str(launcher), '--root', str(root), *args], cwd=cwd,
                                env={**environment, 'PATH': path}, capture_output=True,
                                text=True, timeout=45)
        assert result.returncode == expected, (args, result.stdout, result.stderr, launcher.read_text())
        count += 1
        if args[0] == 'export':
            if result.stderr:
                diagnostics = json.loads(result.stderr)
                export.validate(diagnostics)
                assert diagnostics['exit_code'] == expected
            return result.stdout
        assert result.stderr == '', (result.stderr, launcher.read_text())
        report = json.loads(result.stdout)
        public.validate(report)
        assert report['exit_code'] == expected
        return report

    invoke(['init', '--template', 'mixed'], 0)
    invoke(['validate'], 0)
    invoke(['node'], 0)
    assert invoke(['export', '--format', 'mermaid'], 0).endswith('flowchart LR\n')
    invoke(['export', '--format', 'mermaid', '--out', 'diagram.mmd'], 0)
    assert (root / 'diagram.mmd').is_file()
    (root / 'src').mkdir()
    (root / 'src/main.ts').write_text('export const value = 1;\n')
    (root / 'tsconfig.json').write_text('{"include":["src/**/*.ts"]}')
    (root / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]
''')
    marker = root / 'project-decoy-executed'
    for relative in ['assets/typescript/helper.cjs', 'node_modules/typescript/lib/typescript.js']:
        decoy = root / relative
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_text("require('node:fs').writeFileSync(" + json.dumps(str(marker)) + ", 'executed');throw Error('decoy');")
    result = invoke(['check'], 0, with_node=True)
    assert result['payload']['analysis_complete'] and result['tool_versions']['typescript'] == '5.9.3'
    assert not marker.exists()
    assert invoke(['check'], 2)['payload']['tool_errors'][0]['code'] == 'NODE_UNAVAILABLE'
    helper = installed / 'assets/typescript/helper.cjs'
    original = helper.rename(helper.with_name('saved-helper.cjs'))
    assert invoke(['check'], 2, with_node=True)['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'
    helper.symlink_to(root / 'assets/typescript/helper.cjs')
    assert invoke(['check'], 2, with_node=True)['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_ASSETS_UNAVAILABLE'
    assert not marker.exists()
    helper.unlink()
    original.rename(helper)
    bridge = installed / 'native/linux-x64/libarchway_io.so'
    bridge.unlink()
    invoke(['validate'], 0)
    (root / 'architecture.yaml').unlink()
    (root / 'ARCHITECTURE_AGENT.md').unlink()
    assert invoke(['init', '--template', 'mixed'], 2)['diagnostics'][0]['code'] == 'INIT_UNAVAILABLE'
    print(json.dumps({'route': 'isolated local Git pub activation, explicit setup, generated snapshot',
                      'commit': commit, 'staged_files_verified': len(staged_hashes), 'snapshot_sha256': hashlib.sha256(snapshots[0].read_bytes()).hexdigest(),
                      'cases': count, 'platform': sys.platform}))
