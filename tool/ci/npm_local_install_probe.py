"""Genuine npm installed-route checks; local/global relocation and cache-only exec."""
import argparse
import json
from pathlib import Path, PureWindowsPath
import re
import os
import platform
import shutil
import subprocess
import tempfile

from npm_installed_acceptance import PACKAGE, accept_installation, digest
from npm_cache_exec import exercise_cache
TARGETS = {'linux-x64': ('Linux', 'x86_64', 'linux', 'x64'),
           'macos-arm64': ('Darwin', 'arm64', 'darwin', 'arm64'),
           'windows-x64': ('Windows', 'amd64', 'win32', 'x64')}


def build_command(arguments, *, windows, system_root=None):
    if not windows:
        return arguments
    # Quoted owned fixture arguments; reject expansion and quoting characters.
    if any(any(c in value for c in '\r\n"%!') for value in arguments):
        raise ValueError('Unsafe Windows command argument')
    cmd = PureWindowsPath(system_root) / 'System32/cmd.exe'
    assert cmd.is_absolute()
    return f'"{cmd}" /d /s /c "' + ' '.join(f'"{value}"' for value in arguments) + '"'


def command(arguments):
    windows = os.name == 'nt'
    system_root = os.environ.get('SystemRoot')
    if windows:
        assert (Path(system_root) / 'System32/cmd.exe').is_file()
    return build_command(arguments, windows=windows, system_root=system_root)


def runtime_environment(inherited, node_directory):
    environment = {key: value for key, value in inherited.items()
                   if key.lower() not in {'path', 'node_options', 'node_path',
                                          'node_auth_token', 'npm_token'}
                   and not key.lower().startswith('npm_config_')}
    return {**environment, 'PATH': str(node_directory)}


def checked(arguments, cwd, environment, timeout=30, *, expected_exit=0):
    result = subprocess.run(command(arguments), cwd=cwd, env=environment,
                            capture_output=True, timeout=timeout)
    print(json.dumps({'command': arguments, 'exit': result.returncode,
                      'stdout': result.stdout.decode('utf-8'),
                      'stderr': result.stderr.decode('utf-8')}, ensure_ascii=True), flush=True)
    assert expected_exit is None or result.returncode == expected_exit, 'Installed-route subprocess failed'
    return result


def installation_paths(root, route, *, windows):
    if route == 'global':
        package = root / ('node_modules' if windows else 'lib/node_modules') / PACKAGE
        shim = root / ('archway.cmd' if windows else 'bin/archway')
    else:
        package = root / 'node_modules' / PACKAGE
        shim = root / 'node_modules/.bin' / ('archway.cmd' if windows else 'archway')
    return package, shim


def probe(packed, target, runner_label=None, route='local', wrong_node=None, *, registry_ready=False):
    archive, evidence = verified_tarball(packed, registry_ready=registry_ready)
    system, machine, node_platform, node_arch = TARGETS[target]
    assert (platform.system(), platform.machine().lower()) == (system, machine), 'Wrong actual host'
    if runner_label is not None:
        assert runner_label == {'linux-x64': 'ubuntu-24.04', 'macos-arm64': 'macos-15',
                                'windows-x64': 'windows-2025'}[target], 'Runner and target differ'
    if runner_label == 'ubuntu-24.04':
        release = platform.freedesktop_os_release()
        assert (release['ID'], release['VERSION_ID']) == ('ubuntu', '24.04')
    elif runner_label == 'macos-15':
        assert platform.mac_ver()[0].split('.')[0] == '15'
    elif runner_label == 'windows-2025':
        assert platform.version().split('.')[-1] == '26100', 'Expected Windows Server 2025 build'
        assert platform.win32_edition().startswith('Server'), 'Expected Windows Server edition'
    node = Path(shutil.which('node')).resolve()
    npm = node.parent / ('npm.cmd' if os.name == 'nt' else 'npm')
    assert npm.is_file(), 'npm must accompany pinned Node'
    with tempfile.TemporaryDirectory(prefix='archway npm install ') as temporary:
        base = Path(temporary).resolve()  # Canonical /private path on macOS.
        environment = runtime_environment(os.environ, node.parent)
        assert shutil.which('dart', path=environment['PATH']) is None
        for name in ['userconfig', 'globalconfig']:
            config = base / (name + '.npmrc')
            config.write_text('', encoding='utf-8')
            environment['npm_config_' + name] = str(config)
        environment.update(npm_config_cache=str(base / 'empty cache ü'),
                           npm_config_registry='http://127.0.0.1:9',
                           npm_config_ignore_scripts='true', npm_config_offline='true',
                           npm_config_audit='false', npm_config_fund='false')
        node_info = json.loads(checked([str(node), '-p',
            'JSON.stringify([process.version,process.platform,process.arch])'], base, environment).stdout)
        assert node_info == ['v24.21.0', node_platform, node_arch], 'Wrong actual Node runtime'
        npm_version = checked([str(npm), '--version'], base, environment).stdout.decode('utf-8').strip()
        assert npm_version == '11.19.0', 'Wrong actual npm runtime'
        project = base / ('local project café' if route == 'local' else 'analysis project café')
        project.mkdir()
        (project / 'package.json').write_text('{"private":true}\n', encoding='utf-8')
        foreign = base / 'foreign cwd ü'
        foreign.mkdir()
        cases = []
        if route == 'cache':
            cases.append(exercise_cache(base, archive, evidence, target, node, npm,
                                        project, foreign, environment, checked, command, wrong_node=wrong_node))
        else:
            installation_root = project if route == 'local' else base / 'global prefix café'
            install_options = ['-D'] if route == 'local' else ['--global', '--prefix', str(installation_root)]
            checked([str(npm), 'install', *install_options, str(archive), '--ignore-scripts', '--offline',
                     '--no-audit', '--no-fund'], project, environment, timeout=120)
            if route == 'local':
                assert PACKAGE in json.loads((project / 'package.json').read_text(encoding='utf-8'))['devDependencies']
            for phase in ['installed', 'relocated']:
                if phase == 'relocated':
                    previous = installation_root
                    installation_root = installation_root.rename(base / ('relocated ' + route + ' ü'))
                    assert not previous.exists()
                    if route == 'local':
                        project = installation_root
                installed, shim = installation_paths(installation_root, route, windows=os.name == 'nt')
                assert installed.resolve().is_relative_to(installation_root)
                if route == 'global':
                    assert not installed.is_relative_to(project)
                    assert not (project / 'node_modules' / PACKAGE).exists()
                result = accept_installation(shim, project, foreign, installed, installation_root,
                                             evidence, base / (phase + ' init café'), environment, checked, command, target=target, wrong_node=wrong_node)
                cases.append({'phase': phase, **result})
        return {'scope': route + ' npm help/version/init and bounded TypeScript analysis; full delivery acceptance remains open',
                'source_commit': os.environ.get('GITHUB_SHA'), 'run_id': os.environ.get('GITHUB_RUN_ID'),
                'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'), 'tarball_sha256': evidence['sha256'],
                'target': target, 'host': platform.platform(), 'node': node_info, 'npm': npm_version,
                'route': {'local': 'local-devDependency', 'global': 'global-prefix', 'cache': 'npm-exec-cache'}[route],
                'cases': cases, 'relocation': route != 'cache',
                **({'registry_ready': True} if registry_ready else {})}


def verified_tarball(packed, *, registry_ready=False):
    evidence = json.loads((packed / 'packed-evidence.json').read_text(encoding='utf-8'))
    if evidence.get('registry_ready', False) is not registry_ready:
        raise ValueError('Packed evidence registry intent differs')
    filename = evidence['filename']
    if not isinstance(filename, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*\.tgz', filename):
        raise ValueError('Invalid packed filename')
    archive = packed / filename
    if sorted(packed.rglob('*.tgz')) != [archive] or archive.is_symlink() or not archive.is_file():
        raise ValueError('Expected exactly one ordinary packed tarball')
    if type(evidence['compressed_bytes']) is not int or archive.stat().st_size != evidence['compressed_bytes']:
        raise ValueError('Packed tarball length mismatch')
    if not re.fullmatch('[0-9a-f]{64}', evidence['sha256']) or digest(archive) != evidence['sha256']:
        raise ValueError('Packed tarball SHA-256 mismatch')
    if (not isinstance(evidence.get('manifest_sha256'), str)
            or not re.fullmatch('[0-9a-f]{64}', evidence['manifest_sha256'])
            or sorted(evidence.get('targets', [])) != ['linux-x64', 'macos-arm64', 'windows-x64']):
        raise ValueError('Invalid packed manifest identity')
    return archive, evidence


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packed-directory', required=True, type=Path)
    parser.add_argument('--target', required=True, choices=['linux-x64', 'macos-arm64', 'windows-x64'])
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--runner-label', choices=['ubuntu-24.04', 'macos-15', 'windows-2025'])
    parser.add_argument('--route', choices=['local', 'global', 'cache'], default='local')
    parser.add_argument('--wrong-node', type=Path)
    parser.add_argument('--registry-ready', action='store_true')
    args = parser.parse_args()
    report = probe(args.packed_directory.resolve(), args.target, args.runner_label, args.route,
                   args.wrong_node.resolve() if args.wrong_node else None, registry_ready=args.registry_ready)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=True) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=True))
