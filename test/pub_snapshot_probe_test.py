"""Probe CLI rejection controls; synthetic identities never certify installation."""
import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'tool/ci/pub_snapshot_probe.py'


class PubSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.evidence = self.base / 'producer'
        self.evidence.mkdir()
        self.saved = {'source': {'commit': 'a' * 40}, 'file_set_sha256': 'b' * 64,
                      'files': {'pubspec.yaml': 'c' * 64}}
        self.report = {'source': self.saved['source'], 'file_set_sha256': 'b' * 64, 'files': 1}

    def rejected(self, reason, *, digest='b' * 64, source='a' * 40):
        for name, value in [('stage-identity', self.saved), ('report', self.report)]:
            (self.evidence / (name + '.json')).write_text(json.dumps(value))
        result = subprocess.run([sys.executable, str(PROBE),
            '--dart', str(self.base / 'not-invoked'), '--node', str(self.base / 'not-invoked'), '--stage-evidence', str(self.evidence),
            '--source', str(self.base), '--combined', str(self.base), '--transports', str(self.base),
            '--expected-source', source, '--expected-digest', digest,
            '--prepared-cache', str(self.base), '--target', {'Linux': 'linux-x64', 'Darwin': 'macos-arm64', 'Windows': 'windows-x64'}[platform.system()],
            '--output', str(self.base / 'output')], capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason.encode(), result.stderr)
        self.assertFalse((self.base / 'output').exists())

    def test_caller_identity_is_checked_before_installation(self):
        self.rejected('Expected stage digest differs', digest='c' * 64)

    def test_caller_source_is_checked_before_installation(self):
        self.rejected('Expected source commit differs', source='d' * 40)

    def test_producer_file_count_is_not_ignored(self):
        self.report['files'] = 2
        self.rejected('Producer report differs')

    def test_producer_source_is_not_ignored(self):
        self.report['source'] = {'commit': 'd' * 40}
        self.rejected('Producer report differs')

    def test_producer_digest_is_not_ignored(self):
        self.report['file_set_sha256'] = 'd' * 64
        self.rejected('Producer report differs')

    @unittest.skipIf(os.name == 'nt', 'Link creation may require Windows privilege')
    def test_dangling_output_alias_cannot_create_another_directory(self):
        (self.base / 'output').symlink_to(self.base / 'elsewhere', target_is_directory=True)
        self.rejected('Evidence output already exists')
        self.assertFalse((self.base / 'elsewhere').exists())


if __name__ == '__main__':
    unittest.main()
