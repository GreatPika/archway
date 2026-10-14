"""Synthetic bundle CLI fixtures; no native payload or npm route is executed."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {'linux-x64': ('Linux', 'x86_64', 'archway', 'libarchway_io.so'),
           'macos-arm64': ('Darwin', 'arm64', 'archway', 'libarchway_io.dylib'),
           'windows-x64': ('Windows', 'AMD64', 'archway.exe', 'archway_io.dll')}
TARBALL = 'archway-architecture-cli-0.1.0.tgz'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ReleaseBundles(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.source = self.base / 'source'
        self.source.mkdir()
        # Copy current tracked packaging inputs into an independent clean Git
        # fixture, so neither old commits nor a clean developer worktree are needed.
        tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', '--',
            'LICENSE', 'CHANGELOG.md', 'pubspec.yaml', 'pubspec.lock', 'bin', 'lib', 'assets/typescript', 'contracts/json',
            'tool/package_delivery.py', 'tool/npm']).decode().split('\0')
        for name in filter(None, tracked):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, path)

        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.source), *args]).decode().strip()

        git('init', '-q')
        git('add', '.')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Synthetic bundle test source')
        self.commit = git('rev-parse', 'HEAD')
        self.identity = {'commit': self.commit, 'tree': git('rev-parse', 'HEAD^{tree}'),
            'lockfile_sha256': {name: digest(self.source / name) for name in
                               ('pubspec.lock', 'assets/typescript/package-lock.json')}}
        shared = {}
        for pattern in ('*.cjs', '*.json', '*.md', 'licenses/*.txt'):
            for path in (self.source / 'assets/typescript').glob(pattern):
                shared[path.relative_to(self.source).as_posix()] = path.read_bytes()
        for name in ('typescript/package.json', 'typescript/lib/typescript.js',
                     'typescript/lib/lib.es2022.d.ts', 'typescript/LICENSE.txt',
                     'yaml/package.json', 'yaml/dist/index.js', 'yaml/LICENSE'):
            shared['assets/typescript/vendor/' + name] = b'SYNTHETIC VENDOR ASSET\n'
        # Equal empty files let link controls retain valid zero-size tar headers.
        for package in ('typescript', 'yaml'):
            shared[f'assets/typescript/vendor/{package}/SYNTHETIC-EMPTY'] = b''
        self.transports = self.base / 'transports'
        installation = self.base / 'installation'
        self.payloads, self.records = {}, {}
        for target, (system, machine, executable, bridge) in TARGETS.items():
            data = {**shared,
                f'bin/{target}/{executable}': ('SYNTHETIC CORE ' + target).encode(),
                f'native/{target}/{bridge}': ('SYNTHETIC BRIDGE ' + target).encode()}
            files = {name: {'size': len(value), 'sha256': hashlib.sha256(value).hexdigest(),
                'mode': (0o666 if target == 'windows-x64' else
                         0o755 if name.startswith('bin/') else 0o644)}
                for name, value in data.items()}
            directory = self.transports / target
            directory.mkdir(parents=True)
            archive = directory / 'installation.tar'
            with tarfile.open(archive, 'w') as stream:
                for name, value in data.items():
                    member = tarfile.TarInfo(name)
                    member.size, member.mode = len(value), files[name]['mode']
                    stream.addfile(member, io.BytesIO(value))
                    if target == 'linux-x64' or not name.startswith('assets/'):
                        path = installation / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(value)
                        path.chmod(member.mode)
            # Claims below are validator inputs, never observed host execution.
            record = {'schema_version': 1, 'source': self.identity, 'target': target,
                'host': {'system': system, 'machine': machine, 'release': 'SYNTHETIC'},
                'checks': {'profile': 'init-only' if target == 'windows-x64' else 'process',
                    'suites': [] if target == 'windows-x64' else [
                        'native_asset_process_smoke.dart', 'cli_process_smoke.dart',
                        'dart_check_process_smoke.dart', 'alias_trace_gap_process_smoke.dart'],
                    'relocated_init': True, 'transported_init': True},
                'runtimes': {'build_dart': 'SYNTHETIC Dart 3.13.3'}, 'files': files,
                'archive': {'name': archive.name, 'sha256': digest(archive)}}
            if target != 'windows-x64':
                record['runtimes'].update(analysis_dart='SYNTHETIC', analysis_node='SYNTHETIC')
            (directory / 'provenance.json').write_text(json.dumps(record))
            self.payloads[target], self.records[target] = data, record

        package = self.base / 'package'
        subprocess.run([sys.executable, str(self.source / 'tool/package_delivery.py'),
                        'npm', str(package), str(installation)], check=True, capture_output=True)
        self.packed = self.base / 'packed'
        self.packed.mkdir()
        archive = self.packed / TARBALL
        paths = sorted(path for path in package.rglob('*') if path.is_file())
        with tarfile.open(archive, 'w:gz') as stream:
            for path in paths:
                name = path.relative_to(package).as_posix()
                member = tarfile.TarInfo('package/' + name)
                member.size = path.stat().st_size
                member.mode = 0o755 if name.startswith('bin/') else 0o644
                stream.addfile(member, io.BytesIO(path.read_bytes()))
        listing = [{'path': path.relative_to(package).as_posix(), 'size': path.stat().st_size}
                   for path in paths]
        unpacked = sum(entry['size'] for entry in listing)
        (self.packed / 'npm-pack.json').write_text(json.dumps([{
            'filename': TARBALL, 'size': archive.stat().st_size,
            'unpackedSize': unpacked, 'files': listing}]))
        (self.packed / 'packed-evidence.json').write_text(json.dumps({
            'scope': 'packed-file acceptance only; no installed-route certification',
            'filename': TARBALL, 'sha256': digest(archive),
            'compressed_bytes': archive.stat().st_size, 'unpacked_bytes': unpacked,
            'files': len(paths), 'manifest_sha256': digest(package / 'manifest.json'),
            'targets': list(TARGETS)}))
        self.guide = self.base / 'guide.txt'
        self.guide.write_text('SYNTHETIC packaging fixture; not executable acceptance.\n')
        self.ci = self.base / 'ci'
        self.ci.mkdir()
        (self.ci / 'observed-run.json').write_text('{"scope":"SYNTHETIC fixture only"}\n')
        self.output = self.base / 'release'

    def invoke(self, commit=None):
        return subprocess.run([sys.executable, str(ROOT / 'tool/release_bundles.py'),
            '--source', str(self.source), '--expected-commit', commit or self.commit,
            '--transports', str(self.transports), '--packed', str(self.packed),
            '--guide', str(self.guide), '--output', str(self.output),
            '--ci-evidence', str(self.ci)], capture_output=True, text=True, timeout=30)

    def test_synthetic_transports_preserve_bundle_bytes_modes_layout_and_evidence(self):
        inputs = [path for root in (self.transports, self.packed, self.ci)
                  for path in root.rglob('*') if path.is_file()]
        before = {path: path.read_bytes() for path in inputs}
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        names = {'archway-0.1.0-' + target + ('.zip' if target == 'windows-x64' else '.tar.gz')
                 for target in TARGETS} | {TARBALL, 'QUICKSTART.txt', 'archway-0.1.0-evidence.zip'}
        self.assertEqual({path.name for path in self.output.iterdir()}, names | {'SHA256SUMS'})
        sums = (self.output / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(sums), len(names))
        self.assertEqual({line.split('  ')[1] for line in sums}, names)
        for line in sums:
            checksum, name = line.split('  ')
            self.assertEqual(digest(self.output / name), checksum)
        for target in TARGETS:
            suffix = '.zip' if target == 'windows-x64' else '.tar.gz'
            archive = self.output / ('archway-0.1.0-' + target + suffix)
            if suffix == '.zip':
                with zipfile.ZipFile(archive) as stream:
                    contents = {name: stream.read(name) for name in stream.namelist()}
                    modes = {name: stream.getinfo(name).external_attr >> 16 & 0o7777 for name in contents}
                    self.assertEqual(len(stream.infolist()), len(contents))
            else:
                with tarfile.open(archive) as stream:
                    members = stream.getmembers()
                    self.assertTrue(all(member.isreg() for member in members))
                    contents = {member.name: stream.extractfile(member).read() for member in members}
                    modes = {member.name: member.mode for member in members}
                    self.assertEqual(len(members), len(contents))
            expected = {**self.payloads[target], 'README.txt': self.guide.read_bytes(),
                        'LICENSE': (self.source / 'LICENSE').read_bytes()}
            schemas = self.source / 'contracts/json'
            expected.update({'schemas/' + name: (schemas / name).read_bytes() for name in (
                'policy.schema.json', 'public-result.schema.json', 'export-diagnostics.schema.json')})
            self.assertEqual({name: data for name, data in contents.items() if name != 'manifest.json'}, expected)
            for name in contents:
                mode = self.records[target]['files'].get(name, {'mode': 0o644})['mode']
                self.assertEqual(modes[name], mode, (target, name))
            manifest = json.loads(contents['manifest.json'])
            self.assertEqual(manifest['source'], self.identity)
            self.assertEqual(manifest['target'], target)
            self.assertEqual(manifest['original_archive'], self.records[target]['archive'])
            self.assertEqual(set(manifest['files']), set(expected))
            for name, entry in manifest['files'].items():
                self.assertEqual(entry, {'sha256': hashlib.sha256(expected[name]).hexdigest(),
                                        'size': len(expected[name]), 'mode': modes[name]})
        with zipfile.ZipFile(self.output / 'archway-0.1.0-evidence.zip') as stream:
            for target in TARGETS:
                for name in ('installation.tar', 'provenance.json'):
                    self.assertEqual(stream.read('original/' + target + '/' + name),
                                     before[self.transports / target / name])
            for name in ('npm-pack.json', 'packed-evidence.json'):
                self.assertEqual(stream.read('npm/' + name), before[self.packed / name])
            self.assertEqual(stream.read('ci/observed-run.json'), before[self.ci / 'observed-run.json'])
            record = json.loads(stream.read('release-packaging.json'))
            self.assertEqual(record['source'], self.identity)
            self.assertEqual(set(record['native_bundles']), set(TARGETS))
        self.assertEqual((self.output / TARBALL).read_bytes(), before[self.packed / TARBALL])
        self.assertEqual((self.output / 'QUICKSTART.txt').read_bytes(), self.guide.read_bytes())
        self.assertEqual({path: path.read_bytes() for path in inputs}, before)

    def test_pub_verifier_requires_original_license_and_public_schema_files(self):
        combined = self.base / 'combined'
        subprocess.run([sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
            'combine', '--expected-commit', self.commit, '--output', str(combined),
            *[str(self.transports / target) for target in TARGETS]], cwd=self.source,
            capture_output=True, check=True, timeout=30)
        stage = self.base / 'pub-stage'
        subprocess.run([sys.executable, str(self.source / 'tool/package_delivery.py'),
                        'pub', str(stage), str(combined / 'installation')],
                       capture_output=True, check=True, timeout=30)
        command = [sys.executable, str(ROOT / 'tool/ci/verify_pub_stage.py'),
            '--stage', str(stage), '--source', str(self.source), '--combined', str(combined),
            '--transports', str(self.transports), '--expected-commit', self.commit]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        checked = json.loads(result.stdout)
        self.assertEqual(checked['files']['LICENSE'], digest(self.source / 'LICENSE'))
        self.assertEqual({name for name in checked['files'] if name.startswith('schemas/')},
                         {'schemas/policy.schema.json', 'schemas/public-result.schema.json',
                          'schemas/export-diagnostics.schema.json'})
        license_path = stage / 'LICENSE'
        original_license = license_path.read_bytes()
        manifest = stage / 'manifest.json'
        original_manifest = manifest.read_bytes()
        license_path.write_bytes(b'Changed license')
        value = json.loads(original_manifest)
        value['sha256']['LICENSE'] = digest(license_path)
        manifest.write_text(json.dumps(value))
        rejected = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('Pub manifest differs from reviewed source/audited assets', rejected.stderr)
        license_path.write_bytes(original_license)
        manifest.write_bytes(original_manifest)
        for relative in ('validate_contract.dart', 'fixtures/policy-empty.json'):
            with self.subTest(relative=relative):
                path = stage / 'schemas' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(self.source / 'contracts/json' / relative, path)
                value = json.loads(original_manifest)
                value['sha256']['schemas/' + relative] = digest(path)
                manifest.write_text(json.dumps(value))
                rejected = subprocess.run(command, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('Pub manifest differs from reviewed source/audited assets', rejected.stderr)
                path.unlink()
                if path.parent != stage / 'schemas':
                    path.parent.rmdir()
                manifest.write_bytes(original_manifest)
        final = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(final.returncode, 0, final.stderr)
        self.assertEqual(json.loads(final.stdout), checked)

    def test_refuses_untracked_public_schema(self):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.source), *args]).decode().strip()

        git('rm', '--cached', '-q', 'contracts/json/policy.schema.json')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Untrack schema fixture')
        self.commit = git('rev-parse', 'HEAD')
        self.identity.update(commit=self.commit, tree=git('rev-parse', 'HEAD^{tree}'))
        for target, record in self.records.items():
            (self.transports / target / 'provenance.json').write_text(json.dumps(record))
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Untracked public schema', result.stderr)
        self.assertFalse(self.output.exists())

        combined = self.base / 'combined'
        subprocess.run([sys.executable, str(ROOT / 'tool/ci/combine_installations.py'),
            'combine', '--expected-commit', self.commit, '--output', str(combined),
            *[str(self.transports / target) for target in TARGETS]], cwd=self.source,
            capture_output=True, check=True, timeout=30)
        stage = self.base / 'pub-stage'
        subprocess.run([sys.executable, str(self.source / 'tool/package_delivery.py'),
                        'pub', str(stage), str(combined / 'installation')],
                       capture_output=True, check=True, timeout=30)
        result = subprocess.run([sys.executable, str(ROOT / 'tool/ci/verify_pub_stage.py'),
            '--stage', str(stage), '--source', str(self.source), '--combined', str(combined),
            '--transports', str(self.transports), '--expected-commit', self.commit],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Untracked public schema', result.stderr)

    def test_refuses_wrong_source_existing_output_and_aliased_transport(self):
        result = self.invoke(commit='0' * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Source checkout differs', result.stderr)
        self.assertFalse(self.output.exists())
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_text('owned by caller')
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release output already exists', result.stderr)
        self.assertEqual(marker.read_text(), 'owned by caller')
        shutil.rmtree(self.output)
        archive = self.transports / 'linux-x64/installation.tar'
        saved = archive.with_suffix('.saved')
        archive.rename(saved)
        archive.symlink_to(saved)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Aliased or nonregular', result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_rehashed_malicious_tar_member_before_extraction(self):
        archive = self.transports / 'linux-x64/installation.tar'
        proof_path = archive.with_name('provenance.json')
        proof = self.records['linux-x64']
        payloads = self.payloads['linux-x64']
        linked = 'assets/typescript/vendor/yaml/SYNTHETIC-EMPTY'
        target = 'assets/typescript/vendor/typescript/SYNTHETIC-EMPTY'
        self.assertEqual(payloads[linked], b'')
        self.assertEqual(payloads[linked], payloads[target])
        # Keep every expected member and matching metadata. The link resolves to
        # identical bytes, so a missing link guard cannot hide behind size, mode,
        # missing-member, unresolved-target, or payload-hash rejection.
        names = [name for name in payloads if name != linked] + [linked]
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.REGTYPE):
            with self.subTest(kind=kind):
                self.output = self.base / ('release-malicious-' + kind.decode())
                with tarfile.open(archive, 'w') as stream:
                    for name in names:
                        member = tarfile.TarInfo(name)
                        member.size = len(payloads[name])
                        member.mode = proof['files'][name]['mode']
                        if name == linked:
                            member.type = kind
                            if kind == tarfile.SYMTYPE:
                                member.linkname = '../typescript/SYNTHETIC-EMPTY'
                            elif kind == tarfile.LNKTYPE:
                                member.linkname = target
                            else:
                                member.name = '../escape'
                        stream.addfile(member, io.BytesIO(payloads[name]))
                proof['archive']['sha256'] = digest(archive)
                proof_path.write_text(json.dumps(proof))
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                rejected = '../escape' if kind == tarfile.REGTYPE else linked
                self.assertIn('Unexpected archive member: ' + rejected, result.stderr)
                self.assertFalse(self.output.exists())
                self.assertFalse((self.base / 'escape').exists())
                self.assertEqual(list(self.base.glob('.archway-release-*')), [])


if __name__ == '__main__':
    unittest.main()
