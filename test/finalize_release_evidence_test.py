"""Synthetic release-validation fixtures; these never represent executable proof."""
import hashlib
import json
import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
from installation_artifact import source_identity
from release_native_smoke import archive_manifest
from native_installer_receipt_fixtures import installer_fixture
from release_receipt_fixtures import native_fixture, npm_fixture, pub_fixture
from release_termination_fixtures import termination_fixture
from release_source_runtime_fixtures import (archive_fixture, source_fixture, npm_runtime_fixture,
                                             source_checkout_fixture)


class FinalizeEvidence(unittest.TestCase):
    def test_native_smoke_refuses_tampered_checksum_before_creating_report(self):
        # Use the real host and pinned Node preflight, but never execute a payload.
        target = {('Linux', 'x86_64'): 'linux-x64', ('Darwin', 'arm64'): 'macos-arm64',
                  ('Windows', 'amd64'): 'windows-x64'}[(platform.system(), platform.machine().lower())]
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = source_checkout_fixture(ROOT, base / 'source')
            identity = source_identity(source)
            release = base / 'release'
            release.mkdir()
            archive_fixture(release, target, identity)
            archive = next(release.iterdir())
            (release / 'SHA256SUMS').write_text(
                hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
            with archive.open('ab') as stream:
                stream.write(b'SYNTHETIC CHECKSUM CORRUPTION')
            report = base / 'must-not-exist' / 'report.json'
            result = subprocess.run([sys.executable, str(source / 'tool/ci/release_native_smoke.py'),
                '--release-directory', str(release), '--expected-commit', identity['commit'],
                '--target', target, '--report', str(report)], cwd=source, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('SHA256SUMS mismatch', result.stderr)
            self.assertFalse(report.parent.exists())

    def test_only_evidence_and_checksums_change_and_wrong_archive_receipt_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = source_checkout_fixture(ROOT, base / 'source')
            identity = source_identity(source)
            release = base / 'release'
            release.mkdir()
            reports = base / 'reports'
            for target in ('linux-x64', 'macos-arm64', 'windows-x64'):
                name = 'archway-0.1.0-' + target + ('.zip' if target == 'windows-x64' else '.tar.gz')
                manifest = archive_fixture(release, target, identity)
                directory = reports / target
                directory.mkdir(parents=True)
                native = native_fixture(directory, target, identity)
                native['acceptance']['source_suite'] = source_fixture(directory, target, identity, source, manifest,
                    native['acceptance']['fixtures']['manifest'])
                (directory / 'report.json').write_text(json.dumps({
                    'source': identity, 'target': target, 'ci_host_verified': True,
                    **native,
                    'installer': installer_fixture(directory, target, archive_manifest(
                        release / name, target == 'windows-x64')[1]['manifest.json']['sha256'], identity['commit']),
                    'archive': name, 'archive_sha256': hashlib.sha256((release / name).read_bytes()).hexdigest(),
                    'native_commands': ['help', 'version', 'init', 'validate', 'export'],
                    'typescript': [{'case': c, 'exit': n} for c,n in [
                        ('clean',0),('dependency-violation',1),('unsupported-option',64),
                        ('missing-owned-helper',2),('restored-clean',0)]]}))
            (release / 'archway-architecture-cli-0.1.0.tgz').write_bytes(b'SYNTHETIC NPM FIXTURE')
            (release / 'QUICKSTART.txt').write_text('Synthetic unit fixture only.\n')
            with zipfile.ZipFile(release / 'archway-0.1.0-evidence.zip', 'w') as stream:
                stream.writestr('release-packaging.json', json.dumps({'source': identity}))
                stream.writestr('original-proof.txt', 'Synthetic fixture only')
            (release / 'SHA256SUMS').write_text(''.join(
                hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
                for p in sorted(release.iterdir())))
            output = base / 'final'
            command = [sys.executable, str(source / 'tool/ci/finalize_release_evidence.py'),
                '--release-directory', str(release), '--reports', str(reports),
                '--expected-commit', identity['commit'], '--output', str(output)]
            result = subprocess.run(command, cwd=source, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / 'archway-0.1.0-linux-x64-unsigned.deb').is_file())
            with zipfile.ZipFile(output / 'archway-0.1.0-evidence.zip') as evidence:
                self.assertFalse(any(name.endswith(('.deb', '.pkg', '.exe')) for name in evidence.namelist()))
            extra = reports / 'linux-x64/installer/test-only-old.deb'
            extra.write_bytes(b'old fixture must never enter release evidence')
            refused = command.copy()
            refused[-1] = str(base / 'unexpected-installer')
            failure = subprocess.run(refused,cwd=source,capture_output=True,text=True)
            self.assertNotEqual(failure.returncode,0)
            self.assertIn('Unexpected installer binary',failure.stderr)
            extra.unlink()
            for original in release.iterdir():
                if original.name not in ('SHA256SUMS', 'archway-0.1.0-evidence.zip'):
                    self.assertEqual(original.read_bytes(), (output / original.name).read_bytes())
            with zipfile.ZipFile(output / 'archway-0.1.0-evidence.zip') as stream:
                self.assertEqual(stream.read('original-proof.txt'), b'Synthetic fixture only')
                self.assertIn('native-smoke/windows-x64.json', stream.namelist())
            for line in (output / 'SHA256SUMS').read_text().splitlines():
                digest, name = line.split('  ')
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
            installed = base / 'installed'
            transport = {'schema_version': 1, 'source': identity, 'file_set_sha256': 'f' * 64,
                         'archive': {'sha256': 'e' * 64, 'size': 42}, 'run_id': '123', 'run_attempt': '1'}
            cases = [{'case': c, 'exit': n} for c,n in [
                ('clean',0),('dependency-violation',1),('unsupported-option',64),
                ('missing-owned-helper',2),('restored-clean',0)]]
            for target in ('linux-x64', 'macos-arm64', 'windows-x64'):
                for route, label in [('local','local-devDependency'),('global','global-prefix'),('cache','npm-exec-cache')]:
                    directory = installed / 'npm' / f'npm-installed-{route}-{target}-123-1'
                    directory.mkdir(parents=True)
                    (directory / 'report.json').write_text(json.dumps({
                        'source_commit': identity['commit'], 'run_id': '123', 'run_attempt': '1',
                        'tarball_sha256': hashlib.sha256((release / 'archway-architecture-cli-0.1.0.tgz').read_bytes()).hexdigest(),
                        'target': target, 'route': label, 'node': ['v24.21.0', {'linux-x64':'linux','macos-arm64':'darwin','windows-x64':'win32'}[target], 'arm64' if target == 'macos-arm64' else 'x64'], 'npm': '11.19.0', 'cases': [
                            {'phase': phase, 'help': 0, 'version': 0, 'init': 0, 'analysis': cases, **npm_fixture(route), **npm_runtime_fixture(directory, target), **termination_fixture(target, route)}
                            for phase in (['cached'] if route == 'cache' else ['installed','relocated'])]}))
                directory = installed / 'pub' / f'pub-installed-{target}-123-1' / 'nested'
                directory.mkdir(parents=True)
                commands = [{'arguments': a, 'exit': 0} for a in
                            [['--help'], ['--version'], ['init', '--template', 'mixed']]]
                (directory / 'report.json').write_text(json.dumps({
                    'source': identity, 'target': target, 'transport': transport,
                    **pub_fixture(directory, target),
                    'file_set_sha256': transport['file_set_sha256'],
                    'phases': {p: {'commands': commands} for p in ['installed', 'poisoned_source_snapshot']}}))
            installed_command = command.copy()
            installed_command[-1] = str(base / 'with-routes')
            installed_command.extend(['--installed-evidence', str(installed), '--run-id', '123',
                                      '--run-attempt', '1', '--expected-pub-transport-json', json.dumps(transport)])
            result = subprocess.run(installed_command, cwd=source, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with zipfile.ZipFile(base / 'with-routes' / 'archway-0.1.0-evidence.zip') as stream:
                self.assertIn('installed-routes/npm/npm-installed-local-linux-x64-123-1/report.json', stream.namelist())
            pub_report = installed / 'pub/pub-installed-linux-x64-123-1/nested/report.json'
            original_pub = pub_report.read_text()
            legacy = json.loads(original_pub)
            legacy['phases']['snapshot_only'] = legacy['phases'].pop('poisoned_source_snapshot')
            pub_report.write_text(json.dumps(legacy))
            installed_command[installed_command.index('--output') + 1] = str(base / 'legacy-pub-phase')
            result = subprocess.run(installed_command, cwd=source, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('pub report source/transport/file-set identity differs', result.stderr)
            self.assertFalse((base / 'legacy-pub-phase').exists())
            pub_report.write_text(original_pub)
            selected = installed / 'npm/npm-installed-local-linux-x64-123-1/report.json'
            original_report = selected.read_text()
            for field, value in [('source_commit', '0' * 40), ('run_id', '124'),
                                 ('run_attempt', '2'), ('tarball_sha256', '0' * 64),
                                 ('target', 'macos-arm64'), ('route', 'global-prefix')]:
                with self.subTest(field=field):
                    changed = json.loads(original_report)
                    changed[field] = value
                    selected.write_text(json.dumps(changed))
                    installed_command[installed_command.index('--output') + 1] = str(base / ('bad-' + field))
                    result = subprocess.run(installed_command, cwd=source, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, field)
                    self.assertFalse((base / ('bad-' + field)).exists())
            selected.write_text('this is not JSON or valid proof')
            installed_command[installed_command.index('--output') + 1] = str(base / 'bad-json')
            result = subprocess.run(installed_command, cwd=source, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / 'bad-json').exists())
            selected.unlink()
            installed_command[installed_command.index('--output') + 1] = str(base / 'missing-report')
            result = subprocess.run(installed_command, cwd=source, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / 'missing-report').exists())
            selected.write_text(original_report)
            pub_report = installed / 'pub/pub-installed-linux-x64-123-1/nested/report.json'
            changed = json.loads(pub_report.read_text())
            changed['transport']['archive']['sha256'] = '0' * 64
            pub_report.write_text(json.dumps(changed))
            installed_command[installed_command.index('--output') + 1] = str(base / 'bad-pub-transport')
            result = subprocess.run(installed_command, cwd=source, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / 'bad-pub-transport').exists())
            bad = reports / 'linux-x64/report.json'
            proof = json.loads(bad.read_text())
            proof['archive_sha256'] = '0' * 64
            bad.write_text(json.dumps(proof))
            command[-1] = str(base / 'must-not-exist')
            result = subprocess.run(command, cwd=source, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / 'must-not-exist').exists())


if __name__ == '__main__':
    unittest.main()
