"""Pure-local candidate envelope controls in the measured pinned-pub tar dialect.

Synthetic bridge and validation records exercise transport shape only. They do
not establish a real Archway export, compiler behavior, or registry acceptance.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import unittest

import pub_stage_transport_archive_test as private_fixture

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tool/ci/pub_stage_transport.py'


class CandidateTransport(unittest.TestCase):
    def setUp(self):
        self.fixture = private_fixture.ArchiveControls()
        self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        self.evidence = self.fixture.base / 'evidence'
        stage = self.evidence / 'pub source café'
        spec = stage / 'pubspec.yaml'
        spec.write_text(spec.read_text().replace('publish_to: none', 'publish_to: https://pub.dev'))
        for name in ['LICENSE', 'README.md', 'CHANGELOG.md']:
            (stage / name).write_text('Synthetic structural fixture only.\n')
        files = {p.relative_to(stage).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in stage.rglob('*') if p.is_file() and p.name != 'manifest.json'}
        manifest = json.loads((stage / 'manifest.json').read_text())
        manifest.update(private=False, sha256=files.copy())
        (stage / 'manifest.json').write_text(json.dumps(manifest))
        files['manifest.json'] = hashlib.sha256((stage / 'manifest.json').read_bytes()).hexdigest()
        self.upload = self.evidence / 'pub-package.tar.gz'
        def pub_mode(member):
            member.mode = 0o755 if member.isdir() or member.mode & 0o111 else 0o644
            return member
        with tarfile.open(self.upload, 'w:gz', format=tarfile.USTAR_FORMAT) as stream:
            for path in sorted(stage.rglob('*')):
                stream.add(path, arcname=path.relative_to(stage).as_posix(), recursive=False, filter=pub_mode)
        proof = {'sha256': hashlib.sha256(self.upload.read_bytes()).hexdigest(),
                 'size': self.upload.stat().st_size,
                 'unpacked_bytes': sum((stage / name).stat().st_size for name in files), 'files': len(files)}
        saved = json.loads((self.evidence / 'stage-identity.json').read_text())
        saved.update(files=files, file_set_sha256=hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
                     registry_ready=True, upload_archive=proof)
        (self.evidence / 'stage-identity.json').write_text(json.dumps(saved))
        report = {'route': 'synthetic structural control only', 'source': saved['source'],
                  'files': len(files), 'file_set_sha256': saved['file_set_sha256'],
                  'registry_ready': True, 'upload_archive': proof,
                  'dry_run': {'exit_code': 65, 'expected_advisories': 7},
                  'archive_export': {'exit_code': 0, 'expected_advisories': 7}}
        (self.evidence / 'report.json').write_text(json.dumps(report))
        self.output = self.fixture.base / 'candidate-transport'

    def write(self):
        return subprocess.run([sys.executable, str(SCRIPT), 'write', '--stage-evidence', str(self.evidence),
            '--source', str(self.fixture.source), '--expected-source', self.fixture.commit,
            '--run-id', '123', '--run-attempt', '1', '--output', str(self.output), '--registry-ready'],
            capture_output=True, text=True)

    def test_changed_archive_or_validation_status_refuses_transport(self):
        original = self.upload.read_bytes()
        self.upload.write_bytes(original[:-4])
        self.assertNotEqual(self.write().returncode, 0)
        self.assertFalse(self.output.exists())
        self.upload.write_bytes(original)
        path = self.evidence / 'report.json'
        original_report = path.read_text()
        for phase, status in [('dry_run', 0), ('archive_export', False)]:
            with self.subTest(phase=phase, status=status):
                report = json.loads(original_report); report[phase]['exit_code'] = status
                path.write_text(json.dumps(report))
                rejected = self.write()
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('validation results', rejected.stderr)
                self.assertFalse(self.output.exists())

    def test_candidate_envelope_preserves_upload_bytes_and_requires_explicit_intent(self):
        written = self.write()
        self.assertEqual(written.returncode, 0, written.stderr)
        expected = json.loads(written.stdout)
        self.assertEqual(expected['schema_version'], 2)
        with tarfile.open(self.output / 'pub-stage.tar.gz') as envelope:
            self.assertEqual(set(envelope.getnames()),
                             {'pub-package.tar.gz', 'stage-identity.json', 'report.json'})
        received = self.fixture.base / 'candidate-received'
        command = [sys.executable, str(SCRIPT), 'read', '--archive', str(self.output / 'pub-stage.tar.gz'),
                   '--expected-json', json.dumps(expected), '--source', str(self.fixture.source),
                   '--expected-source', self.fixture.commit, '--run-id', '123', '--run-attempt', '1',
                   '--output', str(received)]
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        result = subprocess.run([*command, '--registry-ready'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((received / self.upload.name).read_bytes(), self.upload.read_bytes())
        original = self.evidence / 'pub source café'
        for path in original.rglob('*'):
            if path.is_file():
                self.assertEqual((received / 'pub source café' / path.relative_to(original)).read_bytes(),
                                 path.read_bytes())


if __name__ == '__main__':
    unittest.main()
