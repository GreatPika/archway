"""Host-neutral controls, never native Windows acceptance."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('windows_probe', ROOT / 'tool/ci/native_windows_installer_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class WindowsProbeControls(unittest.TestCase):
    def test_non_windows_refuses_before_creating_output(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            with patch.object(probe.sys, 'platform', 'linux'):
                with self.assertRaisesRegex(ValueError, 'Native Windows'):
                    probe.run_windows(Path(temporary), output, lambda *_: {})
            self.assertFalse(output.exists())

    def test_old_fixture_is_nonvacuous_and_preserves_verified_bytes(self):
        import hashlib
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            bundle.mkdir()
            (bundle / 'payload').write_bytes(b'final bytes')
            manifest = {'version': '0.1.0', 'target': 'windows-x64', 'files': {
                'payload': {'sha256': hashlib.sha256(b'final bytes').hexdigest(), 'size': 11}}}
            (bundle / 'manifest.json').write_text(json.dumps(manifest))
            before = {p.name: p.read_bytes() for p in bundle.iterdir()}
            old = root / 'old'
            probe.prepare_old_fixture(bundle, old)
            record = json.loads((old / 'manifest.json').read_text())
            self.assertEqual(record['version'], '0.0.0')
            self.assertEqual(set(record['files']) - set(manifest['files']), {probe.STALE})
            self.assertEqual(record['files'][probe.STALE]['sha256'],
                             hashlib.sha256((old / probe.STALE).read_bytes()).hexdigest())
            self.assertEqual(before, {p.name: p.read_bytes() for p in bundle.iterdir()})

    def test_compiler_version_uses_engine_self_report_not_pe_or_help(self):
        # Official ISCC 6.3.3 Go emits this line from ISDllGetVersion.
        output = (b'Inno Setup 6 Command-Line Compiler\r\n'
                  b'Compiler engine version: Inno Setup 6.3.3\r\n'
                  b'Successful compile. Output was disabled.\r\n')
        self.assertEqual(probe.compiler_version(output), '6.3.3')
        self.assertEqual(probe.compiler_version(
            b'Compiler engine version: Inno Setup 6.3.0\r\n'), '6.3.0')
        for invalid in (b'0.0.0.0\r\n', b'6.7.1.0',
                        b'Inno Setup 6 Command-Line Compiler\r\n',
                        b'Compiler engine version: Inno Setup 6.2.9\r\n',
                        b'Compiler engine version: Inno Setup 6.7.1 beta\r\n',
                        output + output):
            with self.subTest(output=invalid), self.assertRaises(ValueError):
                probe.compiler_version(invalid)

    def test_compiler_preflight_uses_fixed_stdin_without_emitting_installer(self):
        from unittest.mock import patch
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            compiler = root / 'ISCC.exe'
            compiler.write_bytes(b'preinstalled compiler fixture')
            bundle = root / 'bundle'
            bundle.mkdir()
            (bundle / 'manifest.json').write_text('{"version":"unexpected"}')
            result = subprocess.CompletedProcess([], 0,
                b'Compiler engine version: Inno Setup 6.7.1\r\n', b'')
            with patch.object(probe.sys, 'platform', 'win32'), patch.object(
                    probe.platform, 'machine', return_value='AMD64'), patch.object(
                    probe, 'compiler_path', return_value=compiler), patch.object(
                    probe.subprocess, 'run', return_value=result) as execute:
                with self.assertRaisesRegex(ValueError, 'verified 0.1.0 bundle'):
                    probe.run_windows(bundle, root / 'output', lambda *_: {})
            execute.assert_called_once_with([str(compiler), '/O-', '-'],
                capture_output=True, timeout=240,
                input=b'[Setup]\nAppName=Archway compiler preflight\nAppVersion=0\n'
                      b'CreateAppDir=no\nUninstallable=no\nOutput=no\n')
            self.assertEqual((root / 'output/windows-0.stdout.log').read_bytes(), result.stdout)

    def test_failed_preflight_cannot_accept_a_valid_engine_banner(self):
        from unittest.mock import patch
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.CompletedProcess([], 1,
                b'Compiler engine version: Inno Setup 6.7.1\r\n', b'compile failed')
            with patch.object(probe.sys, 'platform', 'win32'), patch.object(
                    probe.platform, 'machine', return_value='AMD64'), patch.object(
                    probe, 'compiler_path', return_value=root / 'ISCC.exe'), patch.object(
                    probe.subprocess, 'run', return_value=result) as execute:
                with self.assertRaisesRegex(ValueError, 'compiler preflight failed'):
                    probe.run_windows(root / 'bundle', root / 'output', lambda *_: {})
            self.assertEqual(execute.call_count, 1)
            self.assertEqual((root / 'output/windows-0.stderr.log').read_bytes(), b'compile failed')

    def test_stale_path_rejects_root_filename_before_registry_access(self):
        from unittest.mock import patch, Mock
        spec = importlib.util.spec_from_file_location('lifecycle', ROOT / 'test/windows_installer_lifecycle.py')
        lifecycle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lifecycle)
        registry = Mock()
        with patch.object(lifecycle.sys, 'platform', 'win32'), patch.dict(
                lifecycle.sys.modules, {'winreg': registry}):
            with self.assertRaisesRegex(ValueError, 'non-root parent'):
                lifecycle.run_lifecycle(Path('old'), Path('new'), 'installer-probe..txt')
        self.assertEqual(registry.mock_calls, [])

    def test_preparation_controls_refuse_before_creating_output(self):
        from unittest.mock import patch
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            bundle.mkdir()
            existing = root / 'existing'
            existing.mkdir()
            with patch.object(probe.sys, 'platform', 'win32'), patch.object(
                    probe.platform, 'machine', return_value='AMD64'):
                for output in (existing, bundle / 'nested'):
                    with self.subTest(output=output), self.assertRaisesRegex(ValueError, 'fresh'):
                        probe.run_windows(bundle, output, lambda *_: {})
                with patch.dict(os.environ, {'ProgramFiles(x86)': str(root / 'missing')}):
                    with self.assertRaisesRegex(ValueError, 'Preinstalled official'):
                        probe.run_windows(bundle, root / 'output', lambda *_: {})
            self.assertFalse((root / 'output').exists())

    def test_old_fixture_refuses_reserved_directory_without_copying(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            (bundle / 'obsolete').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'conflicts'):
                probe.prepare_old_fixture(bundle, root / 'old')
            self.assertFalse((root / 'old').exists())

    def test_timeout_retains_partial_command_logs(self):
        from unittest.mock import patch
        import subprocess
        import os
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(probe.sys, 'platform', 'win32'), patch.object(
                    probe.platform, 'machine', return_value='AMD64'), patch.object(
                    probe, 'compiler_path', return_value=root / 'ISCC.exe'), patch.dict(
                    os.environ, {'SystemRoot': str(root)}), patch.object(
                    probe.subprocess, 'run', side_effect=subprocess.TimeoutExpired(
                        ['query'], 240, output=b'partial out', stderr=b'partial err')):
                with self.assertRaises(subprocess.TimeoutExpired):
                    probe.run_windows(root / 'bundle', root / 'output', lambda *_: {})
            self.assertEqual((root / 'output/windows-0.stdout.log').read_bytes(), b'partial out')
            self.assertEqual((root / 'output/windows-0.stderr.log').read_bytes(), b'partial err')

    def test_registered_install_failure_preserves_primary_and_cleanup_errors(self):
        from unittest.mock import patch, MagicMock
        import os
        import subprocess
        spec = importlib.util.spec_from_file_location('lifecycle', ROOT / 'test/windows_installer_lifecycle.py')
        lifecycle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lifecycle)
        registry = MagicMock(REG_SZ=1, REG_EXPAND_SZ=2)
        commands = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'Programs/Archway'
            def open_key(_, name):
                if name == r'Software\Archway\Installer' and not commands:
                    raise FileNotFoundError()
                return MagicMock()
            registry.OpenKey.side_effect = open_key
            registry.QueryValueEx.side_effect = lambda _, name: (
                str(root) if name == 'Root' else 'wrong path after install', 1)
            def execute(arguments, **_):
                commands.append(arguments)
                if len(commands) == 2:
                    raise RuntimeError('cleanup failed fixture')
                root.mkdir(parents=True, exist_ok=True)
                (root / 'unins000.exe').write_bytes(b'owned fixture')
                return subprocess.CompletedProcess(arguments, 0)
            with patch.object(lifecycle.sys, 'platform', 'win32'), patch.dict(
                    lifecycle.sys.modules, {'winreg': registry}), patch.dict(
                    os.environ, {'LOCALAPPDATA': temporary}):
                with self.assertRaises(AssertionError) as raised:
                    lifecycle.run_lifecycle(Path('old'), Path('new'), probe.STALE,
                                            run_command=execute)
            self.assertEqual(len(commands), 2)
            self.assertEqual(Path(commands[1][0]).name, 'unins000.exe')
            self.assertIn('cleanup failed fixture', '\n'.join(raised.exception.__notes__))


if __name__ == '__main__':
    unittest.main()
