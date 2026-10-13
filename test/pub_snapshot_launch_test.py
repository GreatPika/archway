"""Bounded process-boundary controls for the pub launcher's acceptance oracle."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from pub_snapshot_probe import phase, generated_snapshots
from pub_snapshot_setup import installed_root


class PubLauncherControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()

    def generated_files(self):
        cache = self.base / 'cache café with spaces'
        generated = cache / 'global_packages/archway/bin'
        generated.mkdir(parents=True)
        for name in ['archway', 'setup']:
            (generated / f'{name}.dart-3.13.3.snapshot').write_bytes(name.encode())
        launcher = cache / 'bin' / ('archway.bat' if os.name == 'nt' else 'archway')
        launcher.parent.mkdir()
        launcher.write_bytes(b'generated launcher fixture')
        return cache, generated, launcher

    def test_observed_pub_layout_selects_archway_beside_setup_snapshot(self):
        cache, generated, launcher = self.generated_files()
        actual_launcher, snapshot = generated_snapshots(cache)
        self.assertEqual(actual_launcher, launcher)
        self.assertEqual(snapshot, generated / 'archway.dart-3.13.3.snapshot')

    def test_setup_cannot_stand_in_for_missing_archway_snapshot(self):
        cache, generated, _ = self.generated_files()
        (generated / 'archway.dart-3.13.3.snapshot').unlink()
        with self.assertRaisesRegex(ValueError, 'exactly the pinned'):
            generated_snapshots(cache)

    def test_extra_or_wrong_sdk_snapshots_are_not_accepted(self):
        cache, generated, _ = self.generated_files()
        extra = generated / 'archway.dart-3.14.0.snapshot'
        extra.write_bytes(b'wrong SDK')
        with self.assertRaisesRegex(ValueError, 'exactly the pinned'):
            generated_snapshots(cache)
        (generated / 'archway.dart-3.13.3.snapshot').unlink()
        with self.assertRaisesRegex(ValueError, 'exactly the pinned'):
            generated_snapshots(cache)

    def test_missing_setup_snapshot_is_not_ignored(self):
        cache, generated, _ = self.generated_files()
        (generated / 'setup.dart-3.13.3.snapshot').unlink()
        with self.assertRaisesRegex(ValueError, 'exactly the pinned'):
            generated_snapshots(cache)

    def test_empty_or_directory_snapshot_is_not_accepted(self):
        cache, generated, launcher = self.generated_files()
        snapshot = generated / 'archway.dart-3.13.3.snapshot'
        snapshot.write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'ordinary and unaliased'):
            generated_snapshots(cache)
        snapshot.unlink()
        snapshot.mkdir()
        with self.assertRaisesRegex(ValueError, 'ordinary and unaliased'):
            generated_snapshots(cache)
        snapshot.rmdir()
        snapshot.write_bytes(b'archway')
        launcher.unlink()
        with self.assertRaises(FileNotFoundError):
            generated_snapshots(cache)

    @unittest.skipIf(os.name == 'nt', 'Link creation may require Windows privilege')
    def test_aliased_launcher_or_snapshot_is_not_accepted(self):
        cache, generated, launcher = self.generated_files()
        for candidate in [launcher, generated / 'archway.dart-3.13.3.snapshot']:
            original = candidate.read_bytes()
            candidate.unlink()
            target = self.base / 'outside'
            target.write_bytes(original)
            candidate.symlink_to(target)
            with self.assertRaisesRegex(ValueError, 'ordinary and unaliased'):
                generated_snapshots(cache)
            candidate.unlink()
            candidate.write_bytes(original)

    @unittest.skipIf(os.name == 'nt', 'POSIX executable fixture; real Windows launcher proof remains separate')
    def test_success_exit_cannot_hide_wrong_installed_version(self):
        launcher = self.base / 'fixture'
        launcher.write_text('#!' + sys.executable + '\nimport sys\n'
            "print('archway [--root ROOT] COMMAND [OPTIONS]' if '--help' in sys.argv else 'archway 9.9.9')\n")
        launcher.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'Installed version differs'):
            phase(launcher, self.base / 'phase', os.environ.copy())

    @unittest.skipIf(os.name == 'nt', 'POSIX executable fixture; real Windows launcher proof remains separate')
    def test_success_exit_cannot_hide_wrong_init_envelope(self):
        launcher = self.base / 'fixture'
        launcher.write_text('#!' + sys.executable + '\nimport sys\n'
            "print('archway [--root ROOT] COMMAND [OPTIONS]' if '--help' in sys.argv else "
            "'archway 0.1.0' if '--version' in sys.argv else '{}')\n")
        launcher.chmod(0o755)
        with self.assertRaises((KeyError, AssertionError)):
            phase(launcher, self.base / 'phase', os.environ.copy())

    def test_file_uri_retains_unicode_spaces_and_stays_in_git_cache(self):
        cache = self.base / 'cache'
        installed = cache / 'git/installed café'
        installed.mkdir(parents=True)
        config = self.base / 'package_config.json'
        config.write_text(json.dumps({'packages': [{'name': 'archway', 'rootUri': installed.as_uri()}]}))
        self.assertEqual(installed_root(config, cache), installed)
        config.write_text(json.dumps({'packages': [{'name': 'archway', 'rootUri': self.base.as_uri()}]}))
        with self.assertRaisesRegex(ValueError, 'outside isolated Git cache'):
            installed_root(config, cache)


if __name__ == '__main__':
    unittest.main()
