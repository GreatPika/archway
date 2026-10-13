"""Actual isolated dpkg lifecycle with synthetic bytes, never native CLI acceptance."""
import hashlib
import json
from pathlib import Path
import sys
import unittest

import linux_installer_test
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from native_linux_installer_probe import run_linux


class LinuxNativeProbe(unittest.TestCase):
    def setUp(self):
        fixture = linux_installer_test.LinuxInstaller()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.base, self.bundle, self.fixture = fixture.base, fixture.bundle, fixture.fixture

    def test_installed_callback_sees_final_bytes_and_remove_preserves_foreign_files(self):
        linux_installer_test.require_user_namespace(self)
        observed = []
        def inspect(binary, installation):
            observed.append(binary.read_bytes())
            self.assertFalse((installation / 'obsolete/installer-probe..txt').exists())
            self.assertEqual(json.loads((installation / 'manifest.json').read_text())['version'], '0.1.0')
            return {'scope': 'synthetic callback fixture only'}
        output = self.base / 'native-evidence'
        proof = run_linux(self.bundle, output, self.fixture.commit, inspect,
                          privilege=['unshare', '--user', '--map-root-user'])
        self.assertEqual(observed, [(self.bundle / 'bin/linux-x64/archway').read_bytes()])
        self.assertEqual(proof['cases'], ['install-old', 'upgrade-final', 'installed-command',
                                         'remove', 'foreign-preserved'])
        artifact = output / proof['artifact']['name']
        self.assertEqual(hashlib.sha256(artifact.read_bytes()).hexdigest(), proof['artifact']['sha256'])
        self.assertNotIn('0.0.0', artifact.name)
        self.assertEqual(proof['old_fixture']['version'], '0.0.0')
        self.assertTrue(proof['old_fixture']['test_only'])
        self.assertFalse((output / 'test-only-old.deb').exists())


if __name__ == '__main__':
    unittest.main()
