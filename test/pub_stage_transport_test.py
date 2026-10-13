"""Private transport CLI controls; fixtures do not certify a native pub route."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tool/ci/pub_stage_transport.py'


class TransportControls(unittest.TestCase):
    def test_adjacent_replacement_cannot_replace_caller_archive_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'pub-stage.tar.gz'
            archive.write_bytes(b'changed!')
            expected = {'schema_version': 1, 'source': {'commit': 'a' * 40, 'tree': 'b' * 40,
                'lockfile_sha256': {'pubspec.lock': 'c' * 64, 'assets/typescript/package-lock.json': 'd' * 64}},
                'file_set_sha256': 'e' * 64, 'archive': {'sha256': hashlib.sha256(b'original').hexdigest(),
                'size': 8}, 'run_id': '123', 'run_attempt': '1'}
            replaced = {**expected, 'archive': {'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'size': 8}}
            (root / 'transport.json').write_text(json.dumps(replaced))
            result = subprocess.run([sys.executable, str(SCRIPT), 'read', '--archive', str(archive),
                '--expected-json', json.dumps(expected), '--source', str(root), '--expected-source', 'a' * 40,
                '--run-id', '123', '--run-attempt', '1', '--output', str(root / 'received')], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Transport archive digest differs', result.stderr)
            self.assertFalse((root / 'received').exists())


if __name__ == '__main__':
    unittest.main()
