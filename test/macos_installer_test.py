"""Synthetic packaging/lifecycle fixtures; not macOS or download acceptance."""
import hashlib
import json
import platform
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / 'tool/installers/macos/build.py'


class MacInstaller(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.bundle = self.base / 'bundle'
        self.bundle.mkdir()
        self.files = {}
        self.version = '0.1.0'
        for name in ['bin/macos-arm64/archway', 'native/macos-arm64/libarchway_io.dylib',
                     'assets/typescript/helper.cjs', 'assets/typescript/licenses/pnpm-MIT.txt',
                     'assets/typescript/licenses/yaml-ISC.txt', 'LICENSE', 'README.txt',
                     'schemas/policy.schema.json', 'schemas/public-result.schema.json',
                     'schemas/export-diagnostics.schema.json']:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'SYNTHETIC fixture only\n')
            path.chmod(0o755 if name.startswith('bin/') else 0o644)
            self.files[name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                'size': path.stat().st_size, 'mode': path.stat().st_mode & 0o777}
        self.manifest()
        self.output = self.base / 'stage'

    def manifest(self):
        (self.bundle / 'manifest.json').write_text(json.dumps({
            'schema_version': 1, 'version': self.version, 'target': 'macos-arm64',
            'source': {'commit': 'a' * 40}, 'files': self.files}))

    def stage(self):
        return subprocess.run([sys.executable, str(BUILDER), '--bundle', str(self.bundle),
                               '--output', str(self.output), '--stage-only'],
                              capture_output=True, text=True)

    def script(self, name, fixture_host=True):
        script = (self.output / 'root/usr/local/lib/archway/uninstall.sh'
                  if name == 'uninstall' else self.output / 'scripts' / name)
        fixture = script.read_text().replace('/usr/local', str(self.base / 'system/usr/local'))
        if fixture_host:
            fixture = fixture.replace('Darwin:arm64', platform.system() + ':' + platform.machine())
        if platform.system() != 'Darwin':
            # GNU stat is only a Linux fixture substitution for BSD stat's mode field.
            fixture = fixture.replace("stat -f '%Op'", "stat -c '%a'")
        # Native receipt lookup is a fixture double, never native acceptance.
        pkgutil = self.base / 'pkgutil'
        pkgutil.write_text('#!/bin/sh\n[ -f "' + str(self.base / 'receipt') + '" ]\n')
        pkgutil.chmod(0o755)
        script = self.output / 'scripts' / ('fixture-' + name)
        script.write_text(fixture.replace('/usr/sbin/pkgutil', str(pkgutil)))
        return subprocess.run(['sh', str(script), 'fixture.pkg', '/', '/'],
                              capture_output=True, text=True)

    def install(self):
        self.assertEqual(self.stage().returncode, 0)
        preflight = self.script('preinstall')
        self.assertEqual(preflight.returncode, 0, preflight.stderr)
        root = self.base / 'system/usr/local/lib/archway'
        shutil.copytree(self.output / 'root/usr/local/lib/archway', root, dirs_exist_ok=True)
        result = self.script('postinstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.base / 'receipt').touch()
        return root

    def test_registers_command_and_inventory_after_payload_install(self):
        root = self.install()
        command = self.base / 'system/usr/local/bin/archway'
        self.assertTrue(command.is_symlink())
        self.assertEqual(command.resolve(), root / 'bin/macos-arm64/archway')
        self.assertTrue((root / '.archway-owned.sha256').is_file())

    def test_upgrade_removes_stale_owned_files_but_preserves_foreign_files(self):
        root = self.install()
        (root / 'personal.txt').write_text('keep me')
        (self.bundle / 'assets/typescript/helper.cjs').unlink()
        del self.files['assets/typescript/helper.cjs']
        self.version = '0.1.1'
        self.manifest()
        self.output = self.base / 'upgrade'
        self.install()
        self.assertFalse((root / 'assets/typescript/helper.cjs').exists())
        self.assertEqual((root / 'personal.txt').read_text(), 'keep me')

    def test_upgrade_refuses_modified_owned_file_and_new_foreign_collision(self):
        root = self.install()
        owned = root / 'LICENSE'
        owned.write_text('user modification')
        self.assertNotEqual(self.script('preinstall').returncode, 0)
        self.assertEqual(owned.read_text(), 'user modification')
        shutil.copy2(self.bundle / 'LICENSE', owned)
        foreign = root / 'new.txt'
        foreign.write_text('user file')
        path = self.bundle / 'new.txt'
        path.write_text('new payload')
        self.files['new.txt'] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                 'size': path.stat().st_size, 'mode': 0o644}
        self.manifest()
        self.output = self.base / 'upgrade'
        self.assertEqual(self.stage().returncode, 0)
        self.assertNotEqual(self.script('preinstall').returncode, 0)
        self.assertEqual(foreign.read_text(), 'user file')

    def test_uninstall_preserves_foreign_and_modified_files_and_replaced_command(self):
        root = self.install()
        (root / 'personal.txt').write_text('keep me')
        (root / 'LICENSE').write_text('modified by user')
        command = self.base / 'system/usr/local/bin/archway'
        command.unlink()
        command.write_text('another command')
        result = self.script('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / 'personal.txt').read_text(), 'keep me')
        self.assertEqual((root / 'LICENSE').read_text(), 'modified by user')
        self.assertEqual(command.read_text(), 'another command')
        self.assertFalse((root / 'bin').exists())
        self.assertFalse((root / '.archway-owned.sha256').exists())

    def test_clean_uninstall_removes_owned_root_and_command(self):
        root = self.install()
        result = self.script('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(root.exists())
        self.assertFalse((self.base / 'system/usr/local/bin/archway').is_symlink())

    def test_malformed_inventory_refuses_removal_before_mutation(self):
        root = self.install()
        inventory = root / '.archway-owned.sha256'
        inventory.write_text(inventory.read_text() + 'a' * 64 + ' 644 ../../foreign\n')
        result = self.script('uninstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((root / 'bin/macos-arm64/archway').is_file())
        self.assertTrue((self.base / 'system/usr/local/bin/archway').is_symlink())

    def test_package_rejects_tampering_and_executable_permission_loss(self):
        executable = self.bundle / 'bin/macos-arm64/archway'
        original = executable.read_bytes()
        executable.write_bytes(b'tampered')
        self.assertNotEqual(self.stage().returncode, 0)
        self.assertFalse(self.output.exists())
        executable.write_bytes(original)
        executable.chmod(0o644)
        self.files['bin/macos-arm64/archway']['mode'] = 0o644
        self.manifest()
        self.assertNotEqual(self.stage().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_failed_payload_does_not_register_command_or_ownership(self):
        self.assertEqual(self.stage().returncode, 0)
        self.assertEqual(self.script('preinstall').returncode, 0)
        root = self.base / 'system/usr/local/lib/archway'
        self.assertFalse(root.exists())  # Cancelling before extraction has no mutation.
        shutil.copytree(self.output / 'root/usr/local/lib/archway', root)
        (root / 'bin/macos-arm64/archway').unlink()
        result = self.script('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((root / '.archway-owned.sha256').exists())
        self.assertFalse((self.base / 'system/usr/local/bin/archway').is_symlink())

    @unittest.skipIf(platform.system() == 'Darwin', 'Linux-only unsupported-host control')
    def test_native_host_guard_refuses_linux_before_mutation(self):
        self.assertEqual(self.stage().returncode, 0)
        self.assertNotEqual(self.script('preinstall', fixture_host=False).returncode, 0)
        self.assertFalse((self.base / 'system').exists())

    def test_preflight_refuses_foreign_command_and_aliased_parent(self):
        self.assertEqual(self.stage().returncode, 0)
        directory = self.base / 'system/usr/local/bin'
        directory.mkdir(parents=True)
        command = directory / 'archway'
        command.write_text('foreign executable')
        self.assertNotEqual(self.script('preinstall').returncode, 0)
        self.assertEqual(command.read_text(), 'foreign executable')
        command.unlink()
        command.symlink_to('/missing/foreign-command')
        self.assertNotEqual(self.script('preinstall').returncode, 0)
        command.unlink()
        directory.rmdir()
        other = self.base / 'other'
        other.mkdir()
        directory.symlink_to(other)
        self.assertNotEqual(self.script('preinstall').returncode, 0)
        self.assertEqual(list(other.iterdir()), [])

    def test_preflight_rejects_foreign_root_without_mutation(self):
        self.assertEqual(self.stage().returncode, 0)
        root = self.base / 'system/usr/local/lib/archway'
        root.mkdir(parents=True)
        foreign = root / 'user-file'
        foreign.write_text('keep me')
        result = self.script('preinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(foreign.read_text(), 'keep me')
        self.assertEqual(list(root.iterdir()), [foreign])

    def test_mode_modified_owned_file_is_refused_by_upgrade_and_preserved_on_removal(self):
        root = self.install()
        executable = root / 'bin/macos-arm64/archway'
        executable.chmod(0o644)
        result = self.script('preinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(executable.stat().st_mode & 0o7777, 0o644)
        result = self.script('uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(executable.is_file())
        self.assertEqual(executable.stat().st_mode & 0o7777, 0o644)

    def test_postinstall_rejects_executable_permission_loss_before_registration(self):
        self.assertEqual(self.stage().returncode, 0)
        self.assertEqual(self.script('preinstall').returncode, 0)
        root = self.base / 'system/usr/local/lib/archway'
        shutil.copytree(self.output / 'root/usr/local/lib/archway', root)
        (root / 'bin/macos-arm64/archway').chmod(0o644)
        result = self.script('postinstall')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((root / '.archway-owned.sha256').exists())
        self.assertFalse((self.base / 'system/usr/local/bin/archway').is_symlink())

    def test_output_inside_bundle_directly_or_via_alias_preserves_input(self):
        before = {p.relative_to(self.bundle): p.read_bytes() if p.is_file() else None
                  for p in self.bundle.rglob('*')}
        alias = self.base / 'output-alias'
        alias.symlink_to(self.bundle, target_is_directory=True)
        for parent in (self.bundle, alias):
            with self.subTest(parent=parent):
                self.output = parent / 'new-directory/stage'
                result = self.stage()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('outside the input bundle', result.stderr)
                after = {p.relative_to(self.bundle): p.read_bytes() if p.is_file() else None
                         for p in self.bundle.rglob('*')}
                self.assertEqual(after, before)

    def test_stages_complete_private_payload_without_changing_bytes(self):
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.output / 'root/usr/local/lib/archway'
        for path in self.bundle.rglob('*'):
            if path.is_file():
                copy = payload / path.relative_to(self.bundle)
                self.assertEqual(copy.read_bytes(), path.read_bytes())
                self.assertEqual(copy.stat().st_mode & 0o777, path.stat().st_mode & 0o777)
        self.assertFalse((self.output / 'root/usr/local/bin/archway').exists())
        self.assertTrue((self.output / 'scripts/preinstall').is_file())
        self.assertTrue((payload / 'uninstall.sh').is_file())


if __name__ == '__main__':
    unittest.main()
