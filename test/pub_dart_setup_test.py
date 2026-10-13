"""Prerequisite failures are not native pub acceptance evidence."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PubDartSetupTests(unittest.TestCase):
    def test_wrong_actual_host_rejected_before_download_or_cache_creation(self):
        wrong = 'windows-x64' if platform.system() != 'Windows' else 'macos-arm64'
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'setup'
            result = subprocess.run([sys.executable, str(ROOT / 'tool/ci/setup_pub_dart.py'),
                '--target', wrong, '--source', str(ROOT), '--output', str(output)],
                capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Wrong actual host', result.stderr)
            self.assertFalse(output.exists())

    def test_setup_pins_official_archives_and_isolates_locked_dependency_preparation(self):
        script = (ROOT / 'tool/ci/setup_pub_dart.py').read_text()
        for required in [
            'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/',
            '549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7',
            'c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc',
            '30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e',
            "'pub', 'get', '--enforce-lockfile'", "'PUB_HOSTED_URL': 'https://pub.dev'",
            "'GIT_CONFIG_NOSYSTEM': '1'", "'GIT_CONFIG_GLOBAL': str(empty_config)",
            "'HOME': str(home)", "'USERPROFILE': str(home)",
            "'PUB_CACHE': str(cache)", "'diff', 'HEAD', '--exit-code'",
            'hashlib.file_digest', 'SDK checksum mismatch', 'Space-free canonical setup path required',
        ]:
            with self.subTest(required=required):
                self.assertIn(required, script)
        self.assertLess(script.index('SDK checksum mismatch'), script.index('shutil.unpack_archive'))


if __name__ == '__main__':
    unittest.main()
