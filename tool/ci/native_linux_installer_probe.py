"""Build and exercise the real Debian package in an isolated dpkg root."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from installation_artifact import _sha256

ROOT = Path(__file__).resolve().parents[2]
STALE = 'obsolete/installer-probe..txt'


def run_linux(bundle, output, commit, inspect, *, privilege):
    """Caller verifies bundle provenance and supplies its installed-command probe.

    privilege is explicit: CI uses sudo -n; local synthetic fixtures use a user
    namespace. Neither path changes the host dpkg database or installs tools.
    """
    output.mkdir(parents=True)
    commands = []
    def run(arguments, *, privileged=False):
        command = [*privilege, *arguments] if privileged else arguments
        index = len(commands)
        result = subprocess.run(command, capture_output=True, timeout=180)
        stdout = output / f'linux-{index}.stdout.log'
        stderr = output / f'linux-{index}.stderr.log'
        stdout.write_bytes(result.stdout)
        stderr.write_bytes(result.stderr)
        commands.append({'arguments': list(map(str, command)), 'exit': result.returncode,
                         'stdout_sha256': _sha256(stdout), 'stderr_sha256': _sha256(stderr),
                         'stdout': stdout.name, 'stderr': stderr.name})
        if result.returncode:
            raise ValueError(f'Linux installer command failed ({result.returncode}): {command}: {result.stderr!r}')
        return result.stdout.decode('utf-8', errors='replace')

    compiler = Path(shutil.which('dpkg-deb') or '').resolve(strict=True)
    if not compiler.is_file():
        raise ValueError('Native dpkg-deb compiler is unavailable')
    compiler_identity = {'path': str(compiler), 'sha256': _sha256(compiler),
                         'version': run([str(compiler), '--version'])}
    artifact = output / 'archway-0.1.0-linux-x64-unsigned.deb'
    before = _sha256(bundle / 'manifest.json')
    temp = Path(tempfile.mkdtemp(prefix='archway installer ')).resolve()
    system = temp / 'system'
    system.mkdir()
    try:
        old = temp / 'test-only-old-bundle'
        shutil.copytree(bundle, old)
        stale = old / STALE
        stale.parent.mkdir()
        stale.write_bytes(b'Test-only previous-generation owned file.\n')
        stale.chmod(0o644)
        manifest = json.loads((old / 'manifest.json').read_text())
        manifest['version'] = '0.0.0'
        manifest['files'][STALE] = {'mode': 0o644, 'size': stale.stat().st_size,
                                    'sha256': _sha256(stale)}
        (old / 'manifest.json').write_text(json.dumps(manifest) + '\n')
        old_deb = temp / 'test-only-old.deb'
        for payload, destination in ((old, old_deb), (bundle, artifact)):
            run([sys.executable, str(ROOT / 'tool/installers/linux/build.py'),
                 '--bundle', str(payload), '--expected-commit', commit,
                 '--output', str(destination)])
        old_identity = {'version': '0.0.0', 'test_only': True,
                        'manifest_sha256': _sha256(old / 'manifest.json'),
                        'artifact_sha256': _sha256(old_deb), 'removed_file': STALE}
        dpkg = ['dpkg', '--root=' + str(system), '--log=' + str(temp / 'dpkg.log'),
                '--force-script-chrootless']
        run([*dpkg, '--install', str(old_deb)], privileged=True)
        installed = system / 'usr/lib/archway'
        if (installed / STALE).read_bytes() != stale.read_bytes():
            raise ValueError('Old installer did not install stale-file control')
        # These are external user bytes, deliberately outside dpkg's inventory.
        foreign = installed / 'user-notes.txt'
        project = system / 'home/user/project/architecture.yaml'
        run([sys.executable, '-c',
             'from pathlib import Path; import sys; '
             'a,b=map(Path,sys.argv[1:]); b.parent.mkdir(parents=True); '
             'a.write_text("preserve foreign file"); b.write_text("preserve project")',
             str(foreign), str(project)], privileged=True)
        run([*dpkg, '--install', str(artifact)], privileged=True)
        if os.path.lexists(installed / STALE):
            raise ValueError('Final upgrade retained obsolete owned bytes')
        expected = json.loads((bundle / 'manifest.json').read_text())['files']
        for name, entry in expected.items():
            path = installed / name
            if path.is_symlink() or _sha256(path) != entry['sha256']:
                raise ValueError('Installed Debian payload differs: ' + name)
        if (installed / 'manifest.json').read_bytes() != (bundle / 'manifest.json').read_bytes():
            raise ValueError('Installed manifest differs')
        command = system / 'usr/bin/archway'
        if not command.is_symlink() or os.readlink(command) != '/usr/lib/archway/bin/linux-x64/archway':
            raise ValueError('Installed command registration differs')
        # The absolute link is rooted inside the isolated filesystem. Execute its
        # exact target there rather than resolve against the author's host /usr.
        command_result = inspect(installed / 'bin/linux-x64/archway', installed)
        run([*dpkg, '--remove', 'archway'], privileged=True)
        if os.path.lexists(command):
            raise ValueError('Debian uninstall retained owned command')
        for name in [*expected, 'manifest.json']:
            if os.path.lexists(installed / name):
                raise ValueError('Debian uninstall retained owned payload: ' + name)
        if foreign.read_text() != 'preserve foreign file' or project.read_text() != 'preserve project':
            raise ValueError('Debian uninstall changed foreign files')
        shutil.copyfile(temp / 'dpkg.log', output / 'dpkg.log')
        if _sha256(bundle / 'manifest.json') != before:
            raise ValueError('Verified input manifest changed')
        return {'artifact': {'name': artifact.name, 'sha256': _sha256(artifact),
                              'size': artifact.stat().st_size},
                'compiler': compiler_identity, 'old_fixture': old_identity,
                'cases': ['install-old', 'upgrade-final', 'installed-command', 'remove', 'foreign-preserved'],
                'installed': command_result, 'commands': commands}
    finally:
        # Only the exact newly-created isolated dpkg root is removed. Never use
        # package cleanup or this test-only operation against the host root.
        run([sys.executable, '-c', 'import shutil,sys; shutil.rmtree(sys.argv[1])',
             str(temp)], privileged=True)
