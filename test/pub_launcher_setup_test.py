"""Setup process boundary; launcher fixture follows pinned pub global_packages.dart."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest

REPO = Path(__file__).resolve().parents[1]
DART = os.environ.get('PUB_DART') or shutil.which('dart')


def sdk_launcher(snapshot):
    # Independent SDK 3.13.3 output, not imported from the implementation.
    return f'''#!/usr/bin/env sh
# This file was created by pub v3.13.3.
# Package: archway
# Version: 0.1.0
# Executable: archway
# Script: archway
if [ -f {snapshot} ]; then
  dart "{snapshot}" "$@"
  # The VM exits with code 253 if the snapshot version is out-of-date.
  # If it is, we need to delete it and run "pub global" manually.
  exit_code=$?
  if [ $exit_code != 253 ]; then
    exit $exit_code
  fi
fi
dart pub global run archway:archway "$@"
'''


@unittest.skipIf(os.name == 'nt' or not DART, 'POSIX setup process fixture')
class PubLauncherSetupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='archway-setup-')
        self.addCleanup(self.temporary.cleanup)
        self.cache = Path(self.temporary.name).resolve() / 'cache café with spaces'
        self.launcher = self.cache / 'bin/archway'
        self.launcher.parent.mkdir(parents=True)
        self.snapshot = self.cache / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
        self.snapshot.parent.mkdir(parents=True)
        config = self.snapshot.parent.parent / '.dart_tool/package_config.json'
        config.parent.mkdir()
        config.write_text(json.dumps({'configVersion': 2, 'packages': [
            {'name': 'archway', 'rootUri': REPO.as_uri() + '/', 'packageUri': 'lib/'}]}))
        self.launcher.write_text(sdk_launcher(self.snapshot))
        self.launcher.chmod(0o751)

    def setup(self):
        return subprocess.run([DART, '--packages=' + str(REPO / '.dart_tool/package_config.json'),
                               str(REPO / 'bin/setup.dart')], cwd=self.temporary.name,
                              env={**os.environ, 'PUB_CACHE': str(self.cache)},
                              capture_output=True, text=True, timeout=30)

    def test_repairs_spaced_cache_and_preserves_sdk_fallback_and_mode(self):
        result = self.setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        content = self.launcher.read_text()
        self.assertIn("if [ -f '" + str(self.snapshot) + "' ]; then", content)
        self.assertIn("  dart '" + str(self.snapshot) + "' \"$@\"", content)
        self.assertTrue(content.endswith('dart pub global run archway:archway "$@"\n'))
        self.assertEqual(self.launcher.stat().st_mode & 0o777, 0o751)

    def test_space_free_cache_and_default_home_are_supported(self):
        original = self.cache
        self.cache = Path(self.temporary.name).resolve() / '.pub-cache'
        original.rename(self.cache)
        self.launcher = self.cache / 'bin/archway'
        self.snapshot = self.cache / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
        self.launcher.write_text(sdk_launcher(self.snapshot))
        environment = {key: value for key, value in os.environ.items() if key != 'PUB_CACHE'}
        result = subprocess.run([DART, '--packages=' + str(REPO / '.dart_tool/package_config.json'),
                                str(REPO / 'bin/setup.dart')],
                               env={**environment, 'HOME': str(Path(self.temporary.name).resolve())},
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("if [ -f '" + str(self.snapshot) + "' ]; then", self.launcher.read_text())

    def test_second_setup_is_byte_and_metadata_preserving(self):
        self.assertEqual(self.setup().returncode, 0)
        before = (self.launcher.read_bytes(), self.launcher.stat().st_mtime_ns)
        self.assertEqual(self.setup().returncode, 0)
        self.assertEqual((self.launcher.read_bytes(), self.launcher.stat().st_mtime_ns), before)

    def test_foreign_or_unknown_sdk_launcher_is_unchanged(self):
        for text in ['#!/bin/sh\necho foreign\n',
                     sdk_launcher(self.snapshot).replace('pub v3.13.3', 'pub v3.14.0'),
                     sdk_launcher(self.snapshot) + 'echo injected\n']:
            with self.subTest(text=text):
                self.launcher.write_text(text)
                self.assertNotEqual(self.setup().returncode, 0)
                self.assertEqual(self.launcher.read_text(), text)

    def test_different_active_package_is_unchanged(self):
        config = self.snapshot.parent.parent / '.dart_tool/package_config.json'
        config.write_text(json.dumps({'configVersion': 2, 'packages': [
            {'name': 'archway', 'rootUri': Path(self.temporary.name).as_uri() + '/'}]}))
        before = self.launcher.read_bytes()
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_bytes(), before)

    def test_symlinked_launcher_and_parent_are_refused(self):
        real = self.launcher.with_name('real')
        self.launcher.rename(real)
        self.launcher.symlink_to(real)
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(real.read_text(), sdk_launcher(self.snapshot))
        self.launcher.unlink()
        real.rename(self.launcher)
        directory = self.launcher.parent
        moved = directory.with_name('real-bin')
        directory.rename(moved)
        directory.symlink_to(moved, target_is_directory=True)
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_text(), sdk_launcher(self.snapshot))

    def test_path_activation_is_unchanged_without_global_config(self):
        text = sdk_launcher(self.snapshot).split('if [ -f ')[0] + 'dart pub global run archway:archway "$@"\n'
        self.launcher.write_text(text)
        shutil.rmtree(self.snapshot.parent.parent)
        self.assertEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_text(), text)

    def test_literal_shell_characters_argv_exit_and_stale_fallback(self):
        old = self.cache
        self.cache = old.with_name("cache $VALUE `touch EXPANDED` ' \" \\")
        old.rename(self.cache)
        self.launcher = self.cache / 'bin/archway'
        self.snapshot = self.cache / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
        self.snapshot.touch()
        self.launcher.write_text(sdk_launcher(self.snapshot))
        self.assertEqual(self.setup().returncode, 0)
        runtime = Path(self.temporary.name) / 'runtime'
        runtime.mkdir()
        fake = runtime / 'dart'
        fake.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                        'print(json.dumps(sys.argv[1:]))\n'
                        'sys.exit(int(os.environ["SNAPSHOT_EXIT"]) if sys.argv[1].endswith(".snapshot") else 17)\n')
        fake.chmod(0o755)
        arguments = ['value with spaces', '$literal', "a'b", '']
        for code in [0, 42, 253]:
            result = subprocess.run([str(self.launcher), *arguments], cwd=self.temporary.name,
                env={**os.environ, 'PATH': str(runtime) + os.pathsep + os.environ['PATH'],
                     'SNAPSHOT_EXIT': str(code)}, capture_output=True, text=True)
            self.assertEqual(result.stderr, '')
            self.assertEqual(result.returncode, 17 if code == 253 else code)
            lines = result.stdout.splitlines()
            self.assertEqual(json.loads(lines[0]), [str(self.snapshot), *arguments])
            if code == 253:
                self.assertEqual(json.loads(lines[1]), ['pub', 'global', 'run', 'archway:archway', *arguments])
        self.assertFalse((Path(self.temporary.name) / 'EXPANDED').exists())


def windows_sdk_launcher(snapshot):
    # Independent pinned pub Windows template; preserve padding and LF bytes.
    padding = ' ' * (260 - len(str(snapshot)))
    return f'''@echo off
rem This file was created by pub v3.13.3.
rem Package: archway
rem Version: 0.1.0
rem Executable: archway
rem Script: archway
if exist "{snapshot}" {padding}(
  call dart "{snapshot}" {padding}%*
  rem The VM exits with code 253 if the snapshot version is out-of-date.
  rem If it is, we need to delete it and run "pub global" manually.
  if not errorlevel 253 (
    goto error
  )
  call dart pub global run archway:archway %*
) else (
  call dart pub global run archway:archway %*
)
goto eof
:error
exit /b %errorlevel%
:eof
'''


@unittest.skipUnless(os.name == 'nt' and DART, 'Native Windows setup process fixture')
class WindowsPubLauncherSetupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='archway-setup-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.cache = self.base / 'cache with spaces'
        self.launcher = self.cache / 'bin/archway.bat'
        self.launcher.parent.mkdir(parents=True)
        self.snapshot = self.cache / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
        self.snapshot.parent.mkdir(parents=True)
        self.config = self.snapshot.parent.parent / '.dart_tool/package_config.json'
        self.config.parent.mkdir()
        self.config.write_text(json.dumps({'configVersion': 2, 'packages': [
            {'name': 'archway', 'rootUri': REPO.as_uri() + '/', 'packageUri': 'lib/'}]}))
        self.launcher.write_bytes(windows_sdk_launcher(self.snapshot).encode('mbcs'))
        runtime = self.base / 'runtime'
        runtime.mkdir()
        stub = runtime / 'dart.cmd'
        python = runtime / 'exit_fixture.py'
        python.write_text('import json, os, sys\nprint(json.dumps(sys.argv[1:]))\n'
            'sys.exit(int(os.environ["SNAPSHOT_EXIT"]) if sys.argv[1].endswith(".snapshot") else 17)\n')
        stub.write_text(f'@echo off\n"{sys.executable}" "{python}" %*\nexit /b %errorlevel%\n')
        self.env = {**os.environ, 'PATH': str(runtime), 'SNAPSHOT_EXIT': '2'}

    def setup(self):
        return subprocess.run([DART, '--packages=' + str(REPO / '.dart_tool/package_config.json'),
                               str(REPO / 'bin/setup.dart')], cwd=self.base,
            env={**os.environ, 'PUB_CACHE': str(self.cache)}, capture_output=True, timeout=30)

    def launch(self, arguments=()):
        sys.path.insert(0, str(REPO / 'tool/ci'))
        from npm_local_install_probe import command
        return subprocess.run(command([str(self.launcher), *arguments]), cwd=self.base,
                              env=self.env, capture_output=True, timeout=15)

    def test_missing_snapshot_fallback_preserves_nonzero_exit(self):
        stock = self.launch()
        print('WINDOWS_PUB_STOCK_FALLBACK_EXIT=' + str(stock.returncode), flush=True)
        self.assertEqual(self.setup().returncode, 0)
        result = self.launch(['value with spaces', 'café'])
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['pub', 'global', 'run', 'archway:archway',
                                                    'value with spaces', 'café'])
        self.assertEqual(result.stderr, b'')

    def test_snapshot_success_failure_and_stale_fallback(self):
        self.snapshot.write_bytes(b'fixture existence control; fake Dart handles execution')
        self.assertEqual(self.setup().returncode, 0)
        for code in [0, 1, 2, 42, 253]:
            with self.subTest(code=code):
                self.env['SNAPSHOT_EXIT'] = str(code)
                result = self.launch(['value with spaces', 'café'])
                self.assertEqual(result.returncode, 17 if code == 253 else code, result.stderr)
                lines = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(lines[0], [str(self.snapshot), 'value with spaces', 'café'])
                self.assertEqual(len(lines), 2 if code == 253 else 1)
                if code == 253:
                    self.assertEqual(lines[1][:4], ['pub', 'global', 'run', 'archway:archway'])
                self.assertEqual(result.stderr, b'')

    def test_repair_is_exact_and_idempotent_and_reactivation_is_supported(self):
        original = self.launcher.read_bytes()
        mode = self.launcher.stat().st_mode
        self.assertEqual(self.setup().returncode, 0)
        expected = original.replace(b'goto eof\n:error\nexit /b %errorlevel%\n:eof\n',
                                    b':error\nexit /b %errorlevel%\n')
        self.assertEqual(self.launcher.read_bytes(), expected)
        self.assertEqual(self.launcher.stat().st_mode, mode)
        before = (expected, self.launcher.stat().st_mtime_ns)
        self.assertEqual(self.setup().returncode, 0)
        self.assertEqual((self.launcher.read_bytes(), self.launcher.stat().st_mtime_ns), before)
        self.launcher.write_bytes(original)
        self.assertEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_bytes(), expected)

    def test_foreign_template_or_active_package_is_unchanged(self):
        original = self.launcher.read_bytes()
        for content in [b'@echo off\necho foreign\n', original.replace(b'3.13.3', b'3.14.0'),
                        original + b'echo injected\n']:
            self.launcher.write_bytes(content)
            self.assertNotEqual(self.setup().returncode, 0)
            self.assertEqual(self.launcher.read_bytes(), content)
        self.launcher.write_bytes(original)
        self.config.write_text(json.dumps({'configVersion': 2, 'packages': [
            {'name': 'archway', 'rootUri': self.base.as_uri() + '/'}]}))
        self.assertNotEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_bytes(), original)

    def test_windows_default_localappdata_cache(self):
        local = self.base / 'LocalAppData'
        moved = local / 'Pub/Cache'
        moved.parent.mkdir(parents=True)
        self.cache.rename(moved)
        launcher = moved / 'bin/archway.bat'
        snapshot = moved / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
        original = windows_sdk_launcher(snapshot).encode('mbcs')
        launcher.write_bytes(original)
        environment = {k: v for k, v in os.environ.items() if k.upper() not in ('PUB_CACHE', 'HOME')}
        environment['LOCALAPPDATA'] = str(local)
        result = subprocess.run([DART, '--packages=' + str(REPO / '.dart_tool/package_config.json'),
                                 str(REPO / 'bin/setup.dart')], cwd=self.base,
                                env=environment, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(launcher.read_bytes(), original.replace(
            b'goto eof\n:error\nexit /b %errorlevel%\n:eof\n', b':error\nexit /b %errorlevel%\n'))

    def test_read_only_mode_is_refused_without_mutation(self):
        original = self.launcher.read_bytes()
        self.launcher.chmod(0o444)
        try:
            self.assertNotEqual(self.setup().returncode, 0)
            self.assertEqual(self.launcher.read_bytes(), original)
            self.assertFalse(self.launcher.stat().st_mode & 0o200)
        finally:
            self.launcher.chmod(0o666)

    def test_path_activation_is_unchanged_without_global_config(self):
        text = windows_sdk_launcher(self.snapshot).split('if exist ')[0] + \
            'call dart pub global run archway:archway %*\n'
        original = text.encode('mbcs')
        self.launcher.write_bytes(original)
        shutil.rmtree(self.snapshot.parent.parent)
        self.assertEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_bytes(), original)

    def test_unicode_encoding_is_preserved(self):
        moved = self.cache.with_name('cache café with spaces')
        self.cache.rename(moved)
        self.cache = moved
        self.launcher = moved / 'bin/archway.bat'
        self.snapshot = moved / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
        original = windows_sdk_launcher(self.snapshot).encode('mbcs')
        self.launcher.write_bytes(original)
        self.assertEqual(self.setup().returncode, 0)
        self.assertEqual(self.launcher.read_bytes(), original.replace(
            b'goto eof\n:error\nexit /b %errorlevel%\n:eof\n', b':error\nexit /b %errorlevel%\n'))


if __name__ == '__main__':
    unittest.main()
