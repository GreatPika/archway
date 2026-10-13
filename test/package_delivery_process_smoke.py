"""Private Linux npm packaging smoke; real prepared installation argument required."""
import hashlib
import json
import shutil
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
from npm_installed_cases import exercise

repository = Path(__file__).resolve().parents[1]
installation = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='archway-package-') as temporary:
    output = Path(temporary) / 'private npm café'
    result = subprocess.run(['/bin/sh', str(repository / 'tool/assemble.sh'),
                             'npm-private-linux', str(output), str(installation)],
                            capture_output=True, text=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    final = subprocess.run(['/bin/sh', str(repository / 'tool/assemble.sh'),
                            'npm', str(Path(temporary) / 'final'), str(installation)],
                           capture_output=True, text=True)
    assert final.returncode != 0 and 'macos-arm64' in final.stderr, final.stderr
    assert not (Path(temporary) / 'final').exists()
    aliased_install = Path(temporary) / 'aliased-input'
    shutil.copytree(installation, aliased_install)
    helper = aliased_install / 'assets/typescript/helper.cjs'
    helper.unlink()
    helper.symlink_to(installation / 'assets/typescript/helper.cjs')
    rejected = subprocess.run(['/bin/sh', str(repository / 'tool/assemble.sh'),
                               'npm-private-linux', str(Path(temporary) / 'bad-stage'), str(aliased_install)],
                              capture_output=True, text=True)
    assert rejected.returncode != 0 and 'aliased' in rejected.stderr, rejected
    assert not (Path(temporary) / 'bad-stage').exists()
    package = json.loads((output / 'package.json').read_text())
    assert package['name'] == 'archway-architecture-cli'
    assert package['private'] is True
    assert 'scripts' not in package
    assert package['bin'] == {'archway': 'bin/archway.cjs'}
    result = subprocess.run(['node', str(output / 'bin/archway.cjs'), '--help'],
                            capture_output=True, text=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    payload = output / 'bin/linux-x64/archway'
    saved_payload = payload.read_bytes()
    marker = Path(temporary) / 'corrupt-payload-executed'
    payload.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
    corrupt = subprocess.run(['node', str(output / 'bin/archway.cjs')],
                             capture_output=True, text=True)
    assert corrupt.returncode == 126 and 'archway launcher:' in corrupt.stderr, corrupt
    assert not marker.exists()
    # A native-looking header is not sufficient: exec can still reject the image.
    payload.write_bytes(saved_payload[:64] + b'\necho CORRUPTED\n')
    corrupt = subprocess.run(['node', str(output / 'bin/archway.cjs')],
                             capture_output=True, text=True)
    assert corrupt.returncode == 126 and 'archway launcher:' in corrupt.stderr, corrupt
    payload.write_bytes(saved_payload)
    for relative in ['bin/linux-x64/archway', 'manifest.json']:
        asset = output / relative
        saved = asset.rename(asset.with_suffix('.saved'))
        for alias in [False, True]:
            if alias:
                asset.symlink_to(saved)
            failed = subprocess.run(['node', str(output / 'bin/archway.cjs')], capture_output=True, text=True)
            assert failed.returncode == 126 and 'archway launcher:' in failed.stderr, failed
        asset.unlink()
        saved.rename(asset)
    unsupported = subprocess.run(['node', '-e',
        "Object.defineProperty(process,'platform',{value:'freebsd'});require(process.argv[1]);",
        str(output / 'bin/archway.cjs')], capture_output=True, text=True)
    assert unsupported.returncode == 126 and 'unsupported target freebsd/' in unsupported.stderr
    # Selection-only error path: no macOS executable is supplied or run here.
    macos_selection = subprocess.run(['node', '-e',
        "Object.defineProperty(process,'platform',{value:'darwin'});"
        "Object.defineProperty(process,'arch',{value:'arm64'});require(process.argv[1]);",
        str(output / 'bin/archway.cjs')], capture_output=True, text=True)
    assert macos_selection.returncode == 126 and 'cannot start macos-arm64 payload' in macos_selection.stderr
    no_node = subprocess.run([str(output / 'bin/archway.cjs')],
                             env={**os.environ, 'PATH': '/missing-runtime'}, capture_output=True, text=True)
    assert no_node.returncode == 127 and 'node' in no_node.stderr, no_node
    packed = subprocess.run(['npm', 'pack', '--ignore-scripts', '--offline', '--json'],
                            cwd=output, capture_output=True, text=True)
    assert packed.returncode == 0, (packed.stdout, packed.stderr)
    metadata = json.loads(packed.stdout)[0]
    files = {entry['path'] for entry in metadata['files']}
    for required in ['assets/typescript/vendor/typescript/lib/typescript.js',
                     'assets/typescript/vendor/typescript/lib/lib.es2022.d.ts',
                     'assets/typescript/vendor/typescript/LICENSE.txt',
                     'assets/typescript/vendor/yaml/LICENSE',
                     'assets/typescript/licenses/pnpm-MIT.txt',
                     'schemas/public-result.schema.json', 'README.md', 'manifest.json']:
        assert required in files, required
    tarball = output / metadata['filename']
    hashes = json.loads((output / 'manifest.json').read_text())['sha256']
    assert files == set(hashes) | {'manifest.json'}
    with tarfile.open(tarball) as archive:
        for relative, expected_hash in hashes.items():
            assert hashlib.sha256(archive.extractfile('package/' + relative).read()).hexdigest() == expected_hash

    environment = {**os.environ, 'PATH': str(Path(shutil.which('node')).parent),
                   'npm_config_cache': str(Path(temporary) / 'npm-cache'),
                   'npm_config_registry': 'http://127.0.0.1:9',
                   'npm_config_script_shell': '/bin/sh', 'npm_config_ignore_scripts': 'true', 'npm_config_offline': 'true',
                   'npm_config_audit': 'false', 'npm_config_fund': 'false'}
    npm = shutil.which('npm')
    project = Path(temporary) / 'local project café'
    project.mkdir()
    (project / 'package.json').write_text('{"private":true}')
    foreign = Path(temporary) / 'foreign cwd café'
    foreign.mkdir()
    def npm_run(arguments, cwd=foreign):
        result = subprocess.run([npm, *arguments], cwd=cwd, env=environment,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, (arguments, result.stdout, result.stderr)
        return result.stdout
    npm_run(['install', '--ignore-scripts', '--offline', '-D', str(tarball)], project)
    assert json.loads((project / 'package.json').read_text())['devDependencies']
    prefix = Path(temporary) / 'global prefix café'
    npm_run(['install', '--global', '--prefix', str(prefix), '--ignore-scripts', '--offline', str(tarball)])
    cache_args = ['exec', '--ignore-scripts', '--offline', '--yes', '--package=' + str(tarball), '--']
    # Ask npm itself which executable its exec environment selects.
    cached = Path(npm_run([*cache_args, '/bin/sh', '-c', 'command -v archway']).strip()).resolve()
    assert cached.is_relative_to(Path(environment['npm_config_cache']) / '_npx'), cached
    assert not cached.is_relative_to(project)
    launchers = {'local': project / 'node_modules/.bin/archway',
                 'global': prefix / 'bin/archway', 'cache': cached}
    installed_cases = {}
    for route, launcher in launchers.items():
        result = subprocess.run([str(launcher), '--root', str(project), 'init', '--template', 'mixed'],
                                cwd=foreign, env=environment, capture_output=True, text=True)
        assert result.returncode == 0, (route, result.stdout, result.stderr)
        report = json.loads(result.stdout)
        assert report['exit_code'] == 0
        for name in ['architecture.yaml', 'ARCHITECTURE.md']:
            (project / name).unlink()
        installed_cases[route] = exercise(launcher, project, foreign, Path(shutil.which('node')).resolve(),
                                          Path(sys.argv[2]).resolve(), environment, repository)
    cached_core = cached.parent / 'linux-x64/archway'
    saved = cached_core.rename(cached_core.with_suffix('.saved'))
    missing = subprocess.run([npm, *cache_args, 'archway', '--help'], cwd=foreign,
                             env=environment, capture_output=True, text=True)
    assert missing.returncode == 126 and 'archway launcher:' in missing.stderr, missing
    saved.rename(cached_core)
    assert 'archway' in npm_run([*cache_args, 'archway', '--help']).lower()
    relocated = prefix.rename(Path(temporary) / 'relocated global café')
    command = [str(relocated / 'bin/archway'), '--root', str(project)]
    for args in [['init', '--template', 'mixed'], ['export', '--format', 'mermaid', '--out', 'relocated.mmd']]:
        result = subprocess.run([*command, *args], cwd=foreign, env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result
    assert (project / 'relocated.mmd').is_file()
    (project / 'architecture.yaml').write_text('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]
''')
    cached_check = json.loads(npm_run([*cache_args, 'archway', '--root', str(project), 'check']))
    assert cached_check['exit_code'] == 0 and cached_check['payload']['analysis_complete']
    print(json.dumps({'relocation': True, 'npm_exec_typescript_check': True, 'packed_hashes_verified': len(hashes),
                      'tarball_sha256': hashlib.sha256(tarball.read_bytes()).hexdigest(),
                      'installed_cases': installed_cases, 'routes': list(launchers), 'cache_payload_selected': True,
                      'npm': npm_run(['--version']).strip(), 'pack': metadata['filename'], 'size': metadata['size'],
                      'unpacked_size': metadata['unpackedSize'], 'files': len(files)}))
