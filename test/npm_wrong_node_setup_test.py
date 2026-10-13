"""Preparation CLI must reject unverified runtime bytes before extraction."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class WrongNodeSetup(unittest.TestCase):
    def test_rejects_changed_official_archive(self):
        script = Path(__file__).resolve().parents[1] / 'tool/ci/setup_npm_wrong_node.py'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'changed.tar.gz'
            archive.write_bytes(b'not the reviewed official archive')
            output = root / 'prepared'
            result = subprocess.run([sys.executable, str(script), '--target', 'linux-x64',
                '--output', str(output), '--archive', str(archive)], capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Wrong-Node archive checksum mismatch', result.stderr)
            self.assertFalse((output / 'runtime.json').exists())


if __name__ == '__main__':
    unittest.main()
