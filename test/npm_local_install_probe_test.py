"""Bounded public CLI controls; fixtures do not certify native installation."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'tool/ci/npm_local_install_probe.py'
sys.path.insert(0, str(PROBE.parent))
import npm_local_install_probe as probe


class NpmLocalProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.packed = self.base / 'packed'
        self.packed.mkdir()
        self.archive = self.packed / 'package.tgz'
        self.archive.write_bytes(b'original')
        self.evidence = {'filename': 'package.tgz',
                         'sha256': hashlib.sha256(b'original').hexdigest(),
                         'compressed_bytes': 8, 'manifest_sha256': 'a' * 64,
                         'targets': ['linux-x64', 'macos-arm64', 'windows-x64']}

    def invoke(self, environment=None, target='linux-x64', route=None):
        (self.packed / 'packed-evidence.json').write_text(json.dumps(self.evidence), encoding='utf-8')
        return subprocess.run([sys.executable, str(PROBE), '--packed-directory', str(self.packed),
                               '--target', target, '--report', str(self.base / 'report.json'),
                               *([] if route is None else ['--route', route])],
                              capture_output=True, env=environment, timeout=20)

    def rejected(self, reason, **kwargs):
        result = self.invoke(**kwargs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason.encode(), result.stderr)
        self.assertFalse((self.base / 'report.json').exists())

    def test_cache_route_verifies_tarball_before_npm_exec(self):
        self.archive.write_bytes(b'modified')
        self.rejected('Packed tarball SHA-256 mismatch', route='cache')

    def test_global_route_verifies_tarball_before_installation(self):
        self.archive.write_bytes(b'modified')
        self.rejected('Packed tarball SHA-256 mismatch', route='global')

    def test_refuses_changed_tarball_before_starting_runtime(self):
        self.archive.write_bytes(b'modified')
        self.rejected('Packed tarball SHA-256 mismatch')

    def test_rejects_missing_manifest_identity(self):
        self.evidence['manifest_sha256'] = ''
        self.rejected('Invalid packed manifest identity')

    def test_refuses_wrong_size(self):
        self.evidence['compressed_bytes'] = 9
        self.rejected('Packed tarball length mismatch')

    def test_refuses_ambiguous_tarballs(self):
        (self.packed / 'other.tgz').write_bytes(b'other')
        self.rejected('Expected exactly one ordinary packed tarball')

    def test_refuses_filename_escape(self):
        for filename in ['../package.tgz', 'nested/package.tgz', r'nested\package.tgz',
                         'C:package.tgz', 'package.tgz\n']:
            with self.subTest(filename=filename):
                self.evidence['filename'] = filename
                self.rejected('Invalid packed filename')

    def test_refuses_aliased_tarball(self):
        original = self.archive.rename(self.base / 'original')
        try:
            self.archive.symlink_to(original)
        except OSError as error:
            self.skipTest(str(error))
        self.rejected('Expected exactly one ordinary packed tarball')

    def test_refuses_wrong_host(self):
        target = 'linux-x64' if platform.system() != 'Linux' else 'macos-arm64'
        self.rejected('Wrong actual host', target=target)

    @unittest.skipUnless(platform.system() == 'Linux', 'POSIX process-boundary fixture')
    def test_refuses_wrong_node_before_npm_install(self):
        runtime = self.base / 'runtime'
        runtime.mkdir()
        (runtime / 'node').write_text('#!/bin/sh\necho \'["v0.0.0","linux","x64"]\'\n')
        (runtime / 'node').chmod(0o755)
        (runtime / 'npm').write_text('#!/bin/sh\nexit 99\n')
        (runtime / 'npm').chmod(0o755)
        self.rejected('Wrong actual Node runtime', environment={**os.environ, 'PATH': str(runtime)})

    @unittest.skipUnless(platform.system() == 'Linux', 'POSIX process-boundary fixture')
    def test_install_failure_is_not_reported_as_acceptance(self):
        runtime = self.base / 'runtime'
        runtime.mkdir()
        (runtime / 'node').write_text('#!/bin/sh\necho \'["v24.21.0","linux","x64"]\'\n')
        (runtime / 'node').chmod(0o755)
        (runtime / 'npm').write_text(
            '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 11.19.0; exit 0; fi\n'
            'printf "%s\\n" "$@"\nprintf "%s\\n" "$PATH" "$npm_config_registry"\nexit 73\n')
        (runtime / 'npm').chmod(0o755)
        result = self.invoke(environment={**os.environ, 'PATH': str(runtime),
                                         'npm_config_registry': 'https://invalid.example',
                                         'NPM_CONFIG_IGNORE_SCRIPTS': 'false'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Installed-route subprocess failed', result.stderr)
        self.assertIn(b'"exit": 73', result.stdout)
        self.assertIn(b'--ignore-scripts', result.stdout)
        self.assertIn(b'--offline', result.stdout)
        self.assertIn(b'--no-audit', result.stdout)
        self.assertIn(b'--no-fund', result.stdout)
        self.assertIn(b'http://127.0.0.1:9', result.stdout)
        self.assertNotIn(b'https://invalid.example', result.stdout)
        self.assertFalse((self.base / 'report.json').exists())

    @unittest.skipUnless(platform.system() == 'Linux', 'POSIX process-boundary fixture')
    def test_global_install_uses_an_isolated_prefix_and_offline_flags(self):
        runtime = self.base / 'runtime'
        runtime.mkdir()
        (runtime / 'node').write_text('#!/bin/sh\necho \'["v24.21.0","linux","x64"]\'\n')
        (runtime / 'node').chmod(0o755)
        (runtime / 'npm').write_text(
            '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 11.19.0; exit 0; fi\nexit 73\n')
        (runtime / 'npm').chmod(0o755)
        result = self.invoke(environment={**os.environ, 'PATH': str(runtime)}, route='global')
        self.assertNotEqual(result.returncode, 0)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        command = records[-1]['command']
        self.assertEqual(command[:3], [str(runtime / 'npm'), 'install', '--global'])
        self.assertEqual(command[3], '--prefix')
        self.assertTrue(Path(command[4]).is_absolute())
        self.assertIn('global prefix café', command[4])
        self.assertEqual(command[5:], [str(self.archive), '--ignore-scripts', '--offline',
                                      '--no-audit', '--no-fund'])
        self.assertFalse((self.base / 'report.json').exists())

    @unittest.skipUnless(platform.system() == 'Linux', 'POSIX process-boundary fixture')
    def test_cache_materialization_uses_npm_exec_instead_of_install(self):
        runtime = self.base / 'runtime'
        runtime.mkdir()
        (runtime / 'node').write_text('#!/bin/sh\necho \'["v24.21.0","linux","x64"]\'\n')
        (runtime / 'node').chmod(0o755)
        (runtime / 'npm').write_text(
            '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 11.19.0; exit 0; fi\nexit 73\n')
        (runtime / 'npm').chmod(0o755)
        result = self.invoke(environment={**os.environ, 'PATH': str(runtime)}, route='cache')
        self.assertNotEqual(result.returncode, 0)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        command = records[-1]['command']
        self.assertEqual(command[:-1], [str(runtime / 'npm'), 'exec', '--ignore-scripts',
            '--offline', '--yes', '--package=' + str(self.archive), '--', 'node'])
        self.assertEqual(Path(command[-1]).name, 'cache locator.cjs')
        self.assertFalse((self.base / 'report.json').exists())

    def test_global_layout_uses_real_platform_shims_without_resolving_them(self):
        prefix = self.base / 'prefix café'
        self.assertEqual(probe.installation_paths(prefix, 'global', windows=False),
                         (prefix / 'lib/node_modules/archway-architecture-cli', prefix / 'bin/archway'))
        self.assertEqual(probe.installation_paths(prefix, 'global', windows=True),
                         (prefix / 'node_modules/archway-architecture-cli', prefix / 'archway.cmd'))
        self.assertEqual(probe.installation_paths(prefix, 'local', windows=True),
                         (prefix / 'node_modules/archway-architecture-cli', prefix / 'node_modules/.bin/archway.cmd'))
        self.assertEqual(probe.installation_paths(prefix, 'local', windows=False),
                         (prefix / 'node_modules/archway-architecture-cli', prefix / 'node_modules/.bin/archway'))

    def test_windows_quoting_control_preserves_generated_shim(self):
        arguments = [r'C:\local project café\node_modules\.bin\archway.cmd',
                     '--root', r'C:\empty project ü', 'init', '--template', 'mixed']
        result = probe.build_command(arguments, windows=True, system_root=r'C:\Windows')
        self.assertEqual(result,
            '\"C:\\Windows\\System32\\cmd.exe\" /d /s /c "'
            '\"C:\\local project café\\node_modules\\.bin\\archway.cmd\" "--root" '
            '\"C:\\empty project ü\" "init" "--template" "mixed""')
        self.assertNotIn('archway.cjs', result)
        self.assertEqual(probe.build_command(arguments, windows=False), arguments)
        with self.assertRaises(ValueError):
            probe.build_command(['%injected%'], windows=True, system_root=r'C:\Windows')

    def test_path_control_removes_windows_case_duplicates_and_npm_overrides(self):
        environment = probe.runtime_environment(
            {'Path': 'dart;other', 'PATH': 'another dart', 'SystemRoot': r'C:\Windows',
             'ComSpec': r'C:\Windows\System32\cmd.exe', 'TEMP': r'C:\temp',
             'NPM_CONFIG_REGISTRY': 'https://bad.example', 'Node_Options': '--require=bad',
             'NODE_AUTH_TOKEN': 'fixture-token'}, r'C:\pinned node')
        self.assertEqual(environment, {'PATH': r'C:\pinned node', 'SystemRoot': r'C:\Windows',
                                      'ComSpec': r'C:\Windows\System32\cmd.exe', 'TEMP': r'C:\temp'})

    def test_refuses_nested_extra_tarball(self):
        (self.packed / 'nested').mkdir()
        (self.packed / 'nested/other.tgz').write_bytes(b'other')
        self.rejected('Expected exactly one ordinary packed tarball')


if __name__ == '__main__':
    unittest.main()
