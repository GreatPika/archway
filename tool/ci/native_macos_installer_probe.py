"""Real unsigned pkg installation and shell lifecycle on disposable macOS CI."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from installation_artifact import _sha256

ROOT = Path(__file__).resolve().parents[2]


def run_macos(bundle, output, inspect):
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise ValueError('Installer lifecycle requires native macOS arm64')
    installed = Path('/usr/local/lib/archway')
    command = Path('/usr/local/bin/archway')
    if os.path.lexists(installed) or os.path.lexists(command):
        raise ValueError('Disposable macOS host already contains Archway files')
    receipt = subprocess.run(['/usr/sbin/pkgutil', '--pkg-info', 'org.archway.cli'], capture_output=True)
    if receipt.returncode == 0:
        raise ValueError('Disposable macOS host already contains an Archway receipt')
    output.mkdir(parents=True)
    commands = []
    def run(arguments):
        index = len(commands)
        result = subprocess.run(arguments, capture_output=True, timeout=240)
        stdout, stderr = output / f'macos-{index}.stdout.log', output / f'macos-{index}.stderr.log'
        stdout.write_bytes(result.stdout)
        stderr.write_bytes(result.stderr)
        commands.append({'arguments': list(map(str, arguments)), 'exit': result.returncode,
                         'stdout': stdout.name, 'stderr': stderr.name,
                         'stdout_sha256': _sha256(stdout), 'stderr_sha256': _sha256(stderr)})
        if result.returncode:
            raise ValueError(f'macOS installer command failed: {arguments}: {result.stderr!r}')
        return result.stdout.decode('utf-8', errors='replace')

    compiler = Path('/usr/bin/pkgbuild')
    compiler_identity = {'path': str(compiler), 'sha256': _sha256(compiler),
                         'version': 'Apple pkgbuild bundled with host (no compiler-version query):\n' +
                                    run(['/usr/bin/sw_vers'])}
    artifact = output / 'archway-0.1.0-macos-arm64-unsigned.pkg'
    with tempfile.TemporaryDirectory(prefix='archway pkg ') as directory:
        base = Path(directory).resolve()
        old = base / 'test-only-old-bundle'
        shutil.copytree(bundle, old)
        stale_name = 'obsolete/installer-probe..txt'
        stale = old / stale_name
        stale.parent.mkdir()
        stale.write_bytes(b'Test-only previous-generation owned file.\n')
        stale.chmod(0o644)
        manifest = json.loads((old / 'manifest.json').read_text())
        manifest['version'] = '0.0.0'
        manifest['files'][stale_name] = {'mode': 0o644, 'size': stale.stat().st_size,
                                       'sha256': _sha256(stale)}
        (old / 'manifest.json').write_text(json.dumps(manifest) + '\n')
        for payload, stage in ((old, base / 'old-build'), (bundle, base / 'final-build')):
            run([sys.executable, str(ROOT / 'tool/installers/macos/build.py'),
                 '--bundle', str(payload), '--output', str(stage)])
        old_pkg = base / 'old-build/archway-0.0.0-macos-arm64-unsigned.pkg'
        shutil.copyfile(base / 'final-build' / artifact.name, artifact)
        old_identity = {'version': '0.0.0', 'test_only': True, 'removed_file': stale_name,
                        'manifest_sha256': _sha256(old / 'manifest.json'),
                        'artifact_sha256': _sha256(old_pkg)}
        install_attempted = False
        uninstall_digest = _sha256(base / 'final-build/root/usr/local/lib/archway/uninstall.sh')
        foreign = installed / 'user-notes.txt'
        try:
            install_attempted = True
            run(['sudo', '-n', '/usr/sbin/installer', '-pkg', str(old_pkg), '-target', '/'])
            if (installed / stale_name).read_bytes() != stale.read_bytes():
                raise ValueError('Old pkg did not install stale-file control')
            foreign = installed / 'user-notes.txt'
            project = base / 'foreign project/architecture.yaml'
            project.parent.mkdir()
            project.write_text('preserve project')
            run(['sudo', '-n', sys.executable, '-c',
                 'from pathlib import Path; import sys; Path(sys.argv[1]).write_text("preserve foreign file")',
                 str(foreign)])
            run(['sudo', '-n', '/usr/sbin/installer', '-pkg', str(artifact), '-target', '/'])
            if os.path.lexists(installed / stale_name):
                raise ValueError('Final pkg retained obsolete owned bytes')
            expected = json.loads((bundle / 'manifest.json').read_text())['files']
            for name, entry in expected.items():
                path = installed / name
                if path.is_symlink() or _sha256(path) != entry['sha256']:
                    raise ValueError('Installed pkg payload differs: ' + name)
            if (installed / 'manifest.json').read_bytes() != (bundle / 'manifest.json').read_bytes():
                raise ValueError('Installed pkg manifest differs')
            if not command.is_symlink() or command.readlink() != installed / 'bin/macos-arm64/archway':
                raise ValueError('Installed pkg command registration differs')
            command_result = inspect(command, installed)
            run(['sudo', '-n', '/bin/sh', str(installed / 'uninstall.sh')])
            if os.path.lexists(command):
                raise ValueError('pkg uninstall retained owned command')
            for name in [*expected, 'manifest.json', 'uninstall.sh', '.archway-owned.sha256']:
                if os.path.lexists(installed / name):
                    raise ValueError('pkg uninstall retained owned payload: ' + name)
            if foreign.read_text() != 'preserve foreign file' or project.read_text() != 'preserve project':
                raise ValueError('pkg uninstall changed foreign files')
            if subprocess.run(['/usr/sbin/pkgutil', '--pkg-info', 'org.archway.cli'],
                              capture_output=True).returncode == 0:
                raise ValueError('pkg uninstall retained registration receipt')
            # Exact test-owned foreign marker only; never recursively remove a mixed root.
            run(['sudo', '-n', '/bin/rm', str(foreign)])
            run(['sudo', '-n', '/bin/rmdir', str(installed)])
        finally:
            original_failure = sys.exc_info()[0] is not None
            if install_attempted and os.path.lexists(installed):
                try:
                    uninstaller = installed / 'uninstall.sh'
                    if not os.path.lexists(uninstaller):
                        uninstaller = base / 'final-build/root/usr/local/lib/archway/uninstall.sh'
                    if uninstaller.is_symlink() or _sha256(uninstaller) != uninstall_digest:
                        raise ValueError('Refusing cleanup through an unverified standard uninstaller')
                    # Its receipt/inventory checks may safely refuse incomplete
                    # partial installs; preserve the original failure diagnostic.
                    run(['sudo', '-n', '/bin/sh', str(uninstaller)])
                    if foreign.is_file() and not foreign.is_symlink() and foreign.read_text() == 'preserve foreign file':
                        run(['sudo', '-n', '/bin/rm', str(foreign)])
                    if installed.is_dir() and not installed.is_symlink() and not any(installed.iterdir()):
                        run(['sudo', '-n', '/bin/rmdir', str(installed)])
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    print(f'Owned macOS test installation cleanup failed: {error}', file=sys.stderr)
                    if not original_failure:
                        raise
    return {'artifact': {'name': artifact.name, 'sha256': _sha256(artifact),
                         'size': artifact.stat().st_size},
            'compiler': compiler_identity, 'old_fixture': old_identity,
            'cases': ['install-old', 'upgrade-final', 'installed-command', 'remove', 'foreign-preserved'],
            'installed': command_result, 'commands': commands}
