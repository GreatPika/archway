"""Actual subprocess failure/timeout output survives installer command checks."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from release_native_smoke import checked


class InstalledCommandLogs(unittest.TestCase):
    def test_unexpected_exit_is_recorded_before_failure(self):
        recorded = []
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                checked([sys.executable, '-c', 'import sys;print("original output");sys.exit(17)'],
                        directory, os.environ.copy(), record=recorded.append)
        self.assertEqual(recorded[0].returncode, 17)
        self.assertIn(b'original output', recorded[0].stdout)

    def test_timeout_retains_partial_output(self):
        recorded = []
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(subprocess.TimeoutExpired):
                checked([sys.executable, '-c', 'import time;print("before timeout",flush=True);time.sleep(10)'],
                        directory, os.environ.copy(), record=recorded.append, timeout=0.2)
        self.assertIsNone(recorded[0].returncode)
        self.assertIn(b'before timeout', recorded[0].stdout)


if __name__ == '__main__':
    unittest.main()
