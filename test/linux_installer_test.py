"""Actual dpkg packaging/lifecycle fixtures; not Ubuntu desktop acceptance."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import unittest

import release_bundle_process_test as release_fixture

ROOT = Path(__file__).resolve().parents[1]


def require_user_namespace(test):
    """Preflight only synthetic fixtures; native release lifecycle stays mandatory."""
    try:
        result = subprocess.run(['unshare', '--user', '--map-root-user', 'true'],
                                capture_output=True, text=True, timeout=10)
    except FileNotFoundError as error:
        test.skipTest(f'Synthetic dpkg fixture needs user namespaces: {error}')
    if result.returncode:
        diagnostic = result.stderr.strip() or result.stdout.strip() or f'exit {result.returncode}'
        test.skipTest(f'Synthetic dpkg fixture needs user namespaces: {diagnostic}')


class LinuxInstaller(unittest.TestCase):
    def setUp(self):
        self.fixture = release_fixture.ReleaseBundles()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        result = self.fixture.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.base = self.fixture.base
        self.bundle = self.base / 'bundle'
        self.bundle.mkdir()
        archive = self.fixture.output / 'archway-0.1.0-linux-x64.tar.gz'
        with tarfile.open(archive) as stream:
            stream.extractall(self.bundle, filter='data')
        self.output = self.base / 'archway.deb'

    def build(self):
        return subprocess.run([sys.executable, str(ROOT / 'tool/installers/linux/build.py'),
            '--bundle', str(self.bundle), '--expected-commit', self.fixture.commit,
            '--output', str(self.output)], capture_output=True, text=True, timeout=30)

    def dpkg(self, *args):
        root = self.base / 'system'
        root.mkdir(exist_ok=True)
        return subprocess.run(['unshare', '--user', '--map-root-user', 'dpkg',
            '--root=' + str(root), '--log=' + str(root / 'dpkg.log'),
            '--force-script-chrootless', *map(str, args)], capture_output=True,
            text=True, timeout=30)

    def test_output_parent_alias_cannot_stage_inside_input(self):
        before = {p.relative_to(self.bundle): p.read_bytes() if p.is_file() else None
                  for p in self.bundle.rglob('*')}
        alias = self.base / 'output-alias'
        alias.symlink_to(self.bundle, target_is_directory=True)
        self.output = alias / 'new-directory/archway.deb'
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside the input bundle', result.stderr)
        after = {p.relative_to(self.bundle): p.read_bytes() if p.is_file() else None
                 for p in self.bundle.rglob('*')}
        self.assertEqual(after, before)

    def test_foreign_installation_is_rejected_before_overwrite(self):
        require_user_namespace(self)
        self.assertEqual(self.build().returncode, 0)
        foreign = self.base / 'system/usr/lib/archway/README.txt'
        foreign.parent.mkdir(parents=True)
        foreign.write_text('belongs to someone else')
        result = self.dpkg('--install', self.output)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('Archway conflict:', result.stderr)
        self.assertEqual(foreign.read_text(), 'belongs to someone else')
        self.assertFalse((self.base / 'system/usr/bin/archway').is_symlink())

    def test_foreign_command_is_rejected_before_payload_install(self):
        require_user_namespace(self)
        self.assertEqual(self.build().returncode, 0)
        command = self.base / 'system/usr/bin/archway'
        command.parent.mkdir(parents=True)
        command.write_text('unrelated command')
        result = self.dpkg('--install', self.output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Archway conflict:', result.stderr)
        self.assertEqual(command.read_text(), 'unrelated command')
        self.assertFalse((self.base / 'system/usr/lib/archway').exists())

    def test_changed_payload_and_existing_output_are_rejected(self):
        payload = self.bundle / 'bin/linux-x64/archway'
        original = payload.read_bytes()
        payload.write_bytes(b'CORRUPTED')
        self.assertNotEqual(self.build().returncode, 0)
        self.assertFalse(self.output.exists())
        payload.write_bytes(original)
        self.output.write_bytes(b'existing artifact')
        self.assertNotEqual(self.build().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b'existing artifact')

    def test_missing_helper_is_rejected_even_when_manifest_omits_it(self):
        name = 'assets/typescript/helper.cjs'
        (self.bundle / name).unlink()
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        del manifest['files'][name]
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_upgrade_removes_stale_owned_file(self):
        require_user_namespace(self)
        name = 'assets/typescript/obsolete.txt'
        stale = self.bundle / name
        stale.write_text('old owned asset')
        manifest_path = self.bundle / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files'][name] = {'mode': 0o644, 'size': stale.stat().st_size,
                                  'sha256': hashlib.sha256(stale.read_bytes()).hexdigest()}
        manifest_path.write_text(json.dumps(manifest))
        self.assertEqual(self.build().returncode, 0)
        installed = self.dpkg('--install', self.output)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        destination = self.base / 'system/usr/lib/archway' / name
        self.assertEqual(destination.read_text(), 'old owned asset')
        self.output.rename(self.base / 'old.deb')
        stale.unlink()
        del manifest['files'][name]
        manifest['version'] = '0.1.1'
        manifest_path.write_text(json.dumps(manifest))
        self.assertEqual(self.build().returncode, 0)
        upgraded = self.dpkg('--install', self.output)
        self.assertEqual(upgraded.returncode, 0, upgraded.stderr)
        self.assertFalse(destination.exists())

    def test_upgrade_refuses_new_payload_collision_without_changing_files(self):
        require_user_namespace(self)
        self.assertEqual(self.build().returncode, 0)
        installed = self.dpkg('--install', self.output)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        destination = self.base / 'system/usr/lib/archway'
        foreign = destination / 'new-asset.txt'
        foreign.write_text('unowned data')
        before = {p.relative_to(destination): p.read_bytes()
                  for p in destination.rglob('*') if p.is_file()}
        self.output.rename(self.base / 'old.deb')
        new = self.bundle / 'new-asset.txt'
        new.write_text('new packaged asset')
        manifest_path = self.bundle / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['version'] = '0.1.1'
        manifest['files'][new.name] = {'mode': 0o644, 'size': new.stat().st_size,
                                      'sha256': hashlib.sha256(new.read_bytes()).hexdigest()}
        manifest_path.write_text(json.dumps(manifest))
        self.assertEqual(self.build().returncode, 0)
        refused = self.dpkg('--install', self.output)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('Archway conflict:', refused.stderr)
        self.assertEqual({p.relative_to(destination): p.read_bytes()
                          for p in destination.rglob('*') if p.is_file()}, before)

    def test_owned_upgrade_and_remove_preserve_unrelated_files(self):
        require_user_namespace(self)
        self.assertEqual(self.build().returncode, 0)
        first = self.dpkg('--install', self.output)
        self.assertEqual(first.returncode, 0, first.stderr)
        system = self.base / 'system'
        unrelated = system / 'usr/lib/archway/user-notes.txt'
        unrelated.write_text('keep me')
        project = system / 'home/user/project/architecture.yaml'
        project.parent.mkdir(parents=True)
        project.write_text('project policy')
        self.output.rename(self.base / 'first.deb')
        executable = self.bundle / 'bin/linux-x64/archway'
        executable.write_bytes(b'UPGRADED SYNTHETIC PAYLOAD')
        manifest = json.loads((self.bundle / 'manifest.json').read_text())
        manifest['version'] = '0.1.1'
        manifest['files']['bin/linux-x64/archway'].update(
            size=executable.stat().st_size,
            sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
        (self.bundle / 'manifest.json').write_text(json.dumps(manifest))
        self.assertEqual(self.build().returncode, 0)
        upgrade = self.dpkg('--install', self.output)
        self.assertEqual(upgrade.returncode, 0, upgrade.stderr)
        self.assertEqual((system / 'usr/lib/archway/bin/linux-x64/archway').read_bytes(),
                         b'UPGRADED SYNTHETIC PAYLOAD')
        removed = self.dpkg('--remove', 'archway')
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse((system / 'usr/bin/archway').is_symlink())
        self.assertFalse((system / 'usr/lib/archway/bin/linux-x64/archway').exists())
        self.assertEqual(unrelated.read_text(), 'keep me')
        self.assertEqual(project.read_text(), 'project policy')

    def test_deb_installs_complete_bytes_and_registers_command(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = subprocess.check_output(['dpkg-deb', '-f', str(self.output),
            'Package', 'Version', 'Architecture'], text=True)
        self.assertIn('Package: archway\n', metadata)
        self.assertIn('Version: 0.1.0\n', metadata)
        self.assertIn('Architecture: amd64\n', metadata)
        extracted = self.base / 'extracted'
        subprocess.run(['dpkg-deb', '-x', str(self.output), str(extracted)], check=True)
        installed = extracted / 'usr/lib/archway'
        for source in self.bundle.rglob('*'):
            if source.is_file():
                self.assertEqual((installed / source.relative_to(self.bundle)).read_bytes(),
                                 source.read_bytes())
        self.assertEqual(os.readlink(extracted / 'usr/bin/archway'),
                         '/usr/lib/archway/bin/linux-x64/archway')


if __name__ == '__main__':
    unittest.main()
