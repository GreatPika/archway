"""Transport CLI fixtures only; these do not establish native acceptance."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

AUDITOR = Path(__file__).resolve().parents[1] / 'tool/ci/audit_installation_transports.py'
TARGETS = {'linux-x64': ('Linux', 'x86_64'), 'macos-arm64': ('Darwin', 'arm64'),
           'windows-x64': ('Windows', 'AMD64')}
SUITES = ['native_asset_process_smoke.py', 'cli_process_smoke.py',
          'dart_check_process_smoke.py', 'alias_trace_gap_process_smoke.py']


class TransportAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), *args]).decode().strip()
        git('init', '-q')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        locks = ['pubspec.lock', 'assets/typescript/package-lock.json']
        for name in locks:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'lock\n')
        git('add', '.')
        git('commit', '-qm', 'Fixture')
        self.commit = git('rev-parse', 'HEAD')
        source = {'commit': self.commit, 'tree': git('rev-parse', 'HEAD^{tree}'),
                  'lockfile_sha256': {n: hashlib.sha256(b'lock\n').hexdigest() for n in locks}}
        self.dirs = []
        for target, host in TARGETS.items():
            directory = self.root / target
            directory.mkdir()
            self.dirs.append(directory)
            # Deliberately opaque bytes: the audit verifies transport, never parses a tar.
            payload = ('opaque ' + target).encode()
            (directory / 'installation.tar').write_bytes(payload)
            record = {'schema_version': 1, 'source': source, 'target': target,
                      'host': dict(system=host[0], machine=host[1], release='fixture'),
                      'checks': dict(profile='init-only' if target == 'windows-x64' else 'process',
                                     suites=[] if target == 'windows-x64' else SUITES,
                                     relocated_init=True, transported_init=True),
                      'files': {'assets/typescript/helper.cjs': dict(size=1, sha256='a' * 64,
                                                                  mode=438 if target == 'windows-x64' else 420)},
                      'archive': dict(name='installation.tar', sha256=hashlib.sha256(payload).hexdigest())}
            (directory / 'provenance.json').write_text(json.dumps(record))

    def invoke(self, directories=None, commit=None):
        return subprocess.run([sys.executable, str(AUDITOR), '--expected-commit', commit or self.commit,
                               '--report', str(self.root / 'report.json'),
                               *map(str, self.dirs if directories is None else directories)],
                              cwd=self.root, capture_output=True, text=True)

    def mutate(self, change):
        path = self.dirs[2] / 'provenance.json'
        data = json.loads(path.read_text())
        change(data)
        path.write_text(json.dumps(data))

    def test_same_source_assets_allow_windows_mode_difference(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((self.root / 'report.json').read_text())
        self.assertEqual(set(report['targets']), set(TARGETS))
        self.assertEqual(report['source']['commit'], self.commit)
        self.assertEqual(report['scope'], 'transport-only; no extraction or package certification')

    def test_wrong_workflow_commit_fails(self):
        self.assertNotEqual(self.invoke(commit='0' * 40).returncode, 0)

    def test_source_identity_mismatch_fails(self):
        original = (self.dirs[2] / 'provenance.json').read_text()
        for field in ('commit', 'tree', 'lockfile_sha256'):
            with self.subTest(field=field):
                (self.dirs[2] / 'provenance.json').write_text(original)
                self.mutate(lambda r: r['source'].__setitem__(field, 'wrong'))
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('source', result.stderr)

    def test_missing_or_duplicate_targets_fail(self):
        for directories in (self.dirs[:2], self.dirs + [self.dirs[0]], [self.dirs[0]] * 3):
            self.assertNotEqual(self.invoke(directories).returncode, 0)

    def test_damaged_archive_fails(self):
        (self.dirs[1] / 'installation.tar').write_bytes(b'damaged')
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_shared_asset_differences_fail(self):
        path = self.dirs[2] / 'provenance.json'
        original = path.read_text()
        for field, value in [('sha256', 'b' * 64), ('size', 2), ('missing', None)]:
            path.write_text(original)
            def change(record):
                if field == 'missing':
                    record['files'].clear()
                else:
                    record['files']['assets/typescript/helper.cjs'][field] = value
            self.mutate(change)
            self.assertNotEqual(self.invoke().returncode, 0)

    def test_invalid_schema_host_or_check_claim_fails(self):
        path = self.dirs[2] / 'provenance.json'
        original = path.read_text()
        changes = [lambda r: r.update(schema_version=2),
                   lambda r: r['host'].update(system='Linux'),
                   lambda r: r['checks'].update(transported_init=1),
                   lambda r: r['checks'].update(relocated_init=False),
                   lambda r: r['checks'].update(profile='process'),
                   lambda r: r['checks'].update(suites=['invented'])]
        for change in changes:
            path.write_text(original)
            self.mutate(change)
            self.assertNotEqual(self.invoke().returncode, 0)

    def test_malformed_file_inventory_fails_even_when_shared(self):
        for value in [dict(size=-1, sha256='a' * 64, mode=420),
                      dict(size=True, sha256='a' * 64, mode=420),
                      dict(size=1, sha256='not-a-hash', mode=420)]:
            for directory in self.dirs:
                path = directory / 'provenance.json'
                record = json.loads(path.read_text())
                record['files'] = {'assets/typescript/helper.cjs': value}
                path.write_text(json.dumps(record))
            self.assertNotEqual(self.invoke().returncode, 0)


if __name__ == '__main__':
    unittest.main()
