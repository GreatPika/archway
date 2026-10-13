"""Portable fixture skips are separate from mandatory native installer acceptance."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DENIED = 'unshare: write failed /proc/self/uid_map: Operation not permitted'


@unittest.skipUnless(sys.platform == 'linux', 'Linux installer fixture control')
class LinuxInstallerCapability(unittest.TestCase):
    def test_denied_namespace_skips_only_lifecycle_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            command = base / 'unshare'
            calls = base / 'calls.jsonl'
            command.write_text(
                f'#!{sys.executable}\n'
                'import json, pathlib, sys\n'
                f'with pathlib.Path({str(calls)!r}).open("a") as stream:\n'
                '    stream.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                f'print({DENIED!r}, file=sys.stderr)\n'
                'sys.exit(1)\n')
            command.chmod(0o755)
            result = subprocess.run(
                [sys.executable, '-m', 'unittest', '-v', 'linux_installer_test',
                 'native_linux_installer_probe_test'], cwd=ROOT,
                env={**os.environ, 'PATH': str(base) + os.pathsep + os.environ['PATH'],
                     'PYTHONPATH': str(ROOT / 'test'), 'TMPDIR': str(base)},
                capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Ran 10 tests', result.stderr)
            self.assertIn('OK (skipped=6)', result.stderr)
            self.assertEqual(result.stderr.count('skipped '), 6)
            self.assertEqual(result.stderr.count(DENIED), 6)
            for name in ('changed_payload_and_existing_output_are_rejected',
                         'deb_installs_complete_bytes_and_registers_command',
                         'missing_helper_is_rejected_even_when_manifest_omits_it',
                         'output_parent_alias_cannot_stage_inside_input'):
                self.assertIn(f'LinuxInstaller.test_{name}) ... ok', result.stderr)
            self.assertEqual([json.loads(line) for line in calls.read_text().splitlines()],
                             [['--user', '--map-root-user', 'true']] * 6)

    def test_command_failure_after_preflight_is_not_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            command = base / 'unshare'
            command.write_text(
                f'#!{sys.executable}\n'
                'import os, sys\n'
                'if sys.argv[1:] == ["--user", "--map-root-user", "true"]:\n'
                '    sys.exit(0)\n'
                'if sys.argv[3] == "dpkg":\n'
                f'    print({DENIED!r}, file=sys.stderr)\n'
                '    sys.exit(42)\n'
                # Allow the native probe to remove its unprivileged temporary
                # directory without obscuring the original dpkg failure.
                'os.execv(sys.argv[3], sys.argv[3:])\n')
            command.chmod(0o755)
            result = subprocess.run(
                [sys.executable, '-m', 'unittest', '-v',
                 'linux_installer_test.LinuxInstaller.'
                 'test_owned_upgrade_and_remove_preserve_unrelated_files',
                 'native_linux_installer_probe_test'], cwd=ROOT,
                env={**os.environ, 'PATH': str(base) + os.pathsep + os.environ['PATH'],
                     'PYTHONPATH': str(ROOT / 'test'), 'TMPDIR': str(base)},
                capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('Ran 2 tests', result.stderr)
            self.assertIn('FAILED (failures=1, errors=1)', result.stderr)
            self.assertNotIn('skipped', result.stderr)
            self.assertIn('42 != 0 : ' + DENIED, result.stderr)
            self.assertIn('Linux installer command failed (42)', result.stderr)


if __name__ == '__main__':
    unittest.main()
