import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from windows_output_lock import exclusive_file_lock


@unittest.skipUnless(os.name == 'nt', 'Win32 sharing-mode fixture is Windows-specific')
class WindowsOutputLockTest(unittest.TestCase):
    def test_real_sharing_conflict_prevents_truncation_and_releases(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'output café'
            path.write_bytes(b'original')
            with exclusive_file_lock(path):
                attempted = subprocess.run([sys.executable, '-c',
                    'import sys; open(sys.argv[1], "wb").write(b"changed")', str(path)],
                    capture_output=True)
                self.assertNotEqual(attempted.returncode, 0)
                self.assertIn(b'PermissionError', attempted.stderr)
            self.assertEqual(path.read_bytes(), b'original')
            path.write_bytes(b'unlocked')
            self.assertEqual(path.read_bytes(), b'unlocked')


if __name__ == '__main__':
    unittest.main()
