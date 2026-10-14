"""CI combine CLI fixtures; dummy bytes never establish native acceptance."""
import hashlib
import gzip
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'tool/ci/combine_installations.py'
TARGETS = {'linux-x64': ('Linux', 'x86_64', 'archway', 'libarchway_io.so'),
           'macos-arm64': ('Darwin', 'arm64', 'archway', 'libarchway_io.dylib'),
           'windows-x64': ('Windows', 'AMD64', 'archway.exe', 'archway_io.dll')}
SUITES = ['native_asset_process_smoke.dart', 'cli_process_smoke.dart',
          'dart_check_process_smoke.dart', 'alias_trace_gap_process_smoke.dart']


class CombineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), *args]).decode().strip()
        git('init', '-q'); git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        locks = ['pubspec.lock', 'assets/typescript/package-lock.json']
        for name in locks:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'lock\n')
        (self.root / 'assets/typescript/helper.cjs').write_bytes(b'shared asset')
        git('add', '.'); git('commit', '-qm', 'Fixture')
        self.commit = git('rev-parse', 'HEAD')
        self.source = dict(commit=self.commit, tree=git('rev-parse', 'HEAD^{tree}'),
                           lockfile_sha256={n: hashlib.sha256(b'lock\n').hexdigest() for n in locks})
        self.dirs = []
        for target, (system, machine, executable, bridge) in TARGETS.items():
            directory = self.root / target
            directory.mkdir(); self.dirs.append(directory)
            data = {f'bin/{target}/{executable}': b'fixture core',
                    f'native/{target}/{bridge}': b'fixture bridge',
                    'assets/typescript/helper.cjs': b'shared asset',
                    'assets/typescript/package-lock.json': b'lock\n'}
            for asset in ['licenses/pnpm-MIT.txt', 'licenses/yaml-ISC.txt',
                          'vendor/typescript/package.json', 'vendor/typescript/lib/typescript.js',
                          'vendor/yaml/package.json', 'vendor/yaml/dist/index.js']:
                data['assets/typescript/' + asset] = b'shared asset'
            mode = 0o666 if target == 'windows-x64' else 0o755
            files = {n: dict(size=len(b), sha256=hashlib.sha256(b).hexdigest(), mode=mode)
                     for n, b in data.items()}
            with tarfile.open(directory / 'installation.tar', 'w') as tar:
                for name, content in data.items():
                    member = tarfile.TarInfo(name); member.size = len(content); member.mode = mode
                    tar.addfile(member, io.BytesIO(content))
            record = dict(schema_version=1, source=self.source, target=target,
                          host=dict(system=system, machine=machine, release='fixture'),
                          checks=dict(profile='init-only' if target == 'windows-x64' else 'process',
                                      suites=[] if target == 'windows-x64' else SUITES,
                                      relocated_init=True, transported_init=True),
                          runtimes=(dict(build_dart='Dart SDK version: 3.13.3') if target == 'windows-x64' else
                                    dict(build_dart='Dart SDK version: 3.13.3', analysis_dart='3.13.3',
                                         analysis_node='v24.21.0')), files=files,
                          archive=dict(name='installation.tar', sha256=self.digest(directory / 'installation.tar')))
            (directory / 'provenance.json').write_text(json.dumps(record))
        self.output = self.root / 'combined'

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def invoke(self, directories=None):
        return subprocess.run([sys.executable, str(CLI), 'combine', '--expected-commit', self.commit,
                               '--output', str(self.output),
                               *map(str, self.dirs if directories is None else directories)],
                              cwd=self.root, capture_output=True, text=True)

    def test_inventory_rejects_unsafe_layout_modes_and_unbounded_sizes(self):
        path = self.dirs[0] / 'provenance.json'
        original = path.read_text()
        with tarfile.open(self.dirs[0] / 'installation.tar') as tar:
            contents = {m.name: tar.extractfile(m).read() for m in tar}
        for name, value in [('../escape', {}), ('/absolute', {}), ('assets//bad', {}),
                            ('assets/../bad', {}), ('assets/evil', {}), ('assets/typescript/unowned.cjs', {}),
                            ('bin/macos-arm64/archway', {}),
                            ('bin/linux-x64/archway', {'mode': 0o4755}),
                            ('bin/linux-x64/archway', {'size': 128 * 1024 * 1024 + 1})]:
            with self.subTest(name=name, value=value):
                record = json.loads(original)
                entry = dict(record['files']['bin/linux-x64/archway']); entry.update(value)
                record['files'][name] = entry
                if value.get('size', 0) <= 100:
                    with tarfile.open(self.dirs[0] / 'installation.tar', 'w') as tar:
                        for member_name, meta in record['files'].items():
                            content = contents.get(member_name, b'fixture core')
                            info = tarfile.TarInfo(member_name); info.size = len(content); info.mode = meta['mode']
                            tar.addfile(info, io.BytesIO(content))
                    record['archive']['sha256'] = self.digest(self.dirs[0] / 'installation.tar')
                path.write_text(json.dumps(record))
                result = self.invoke()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())
        path.write_text(original)
        record = json.loads(original); del record['files']['native/linux-x64/libarchway_io.so']
        path.write_text(json.dumps(record))
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_metadata_rejects_unknown_fields_before_extraction(self):
        path = self.dirs[0] / 'provenance.json'
        record = json.loads(path.read_text()); record['unknown'] = True
        path.write_text(json.dumps(record))
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_shared_required_assets_cannot_be_omitted_from_every_transport(self):
        for directory in self.dirs:
            path = directory / 'provenance.json'; record = json.loads(path.read_text())
            del record['files']['assets/typescript/vendor/typescript/lib/typescript.js']
            with tarfile.open(directory / 'installation.tar') as tar:
                entries = [(m, tar.extractfile(m).read()) for m in tar if m.name in record['files']]
            with tarfile.open(directory / 'installation.tar', 'w') as tar:
                for member, data in entries: tar.addfile(member, io.BytesIO(data))
            record['archive']['sha256'] = self.digest(directory / 'installation.tar')
            path.write_text(json.dumps(record))
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_source_target_and_required_checks_fail_closed(self):
        path = self.dirs[0] / 'provenance.json'; original = path.read_text()
        changes = [lambda r: r['source'].update(commit='0' * 40),
                   lambda r: r['source'].update(tree='0' * 40),
                   lambda r: r['source']['lockfile_sha256'].update({'pubspec.lock': '0' * 64}),
                   lambda r: r.update(target='unknown'),
                   lambda r: r['checks'].update(transported_init=False),
                   lambda r: r.update(files=[]), lambda r: r.update(runtimes=[])]
        for change in changes:
            record = json.loads(original); change(record); path.write_text(json.dumps(record))
            self.assertNotEqual(self.invoke().returncode, 0)
            self.assertFalse(self.output.exists())
        path.write_text(original)
        for directories in [self.dirs[:2], self.dirs + [self.dirs[0]]]:
            self.assertNotEqual(self.invoke(directories).returncode, 0)
        path.write_text(original.replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1'))
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_archive_members_and_actual_bytes_are_verified(self):
        directory = self.dirs[0]; archive = directory / 'installation.tar'
        original = archive.read_bytes(); path = directory / 'provenance.json'
        record = json.loads(path.read_text())
        with tarfile.open(archive) as tar:
            members = [(m, tar.extractfile(m).read()) for m in tar]
        for change in ['duplicate', 'missing', 'unexpected', 'symlink', 'hardlink',
                       'fifo', 'directory', 'size', 'mode', 'hash', 'absolute', 'traversal']:
            with self.subTest(change=change):
                import copy
                entries = copy.deepcopy(members)
                member, content = entries[0]
                if change == 'duplicate': entries.append(entries[0])
                elif change == 'missing': entries.pop()
                elif change == 'unexpected': member.name = 'assets/typescript/unexpected.cjs'
                elif change in ['symlink', 'hardlink', 'fifo', 'directory']:
                    member.type = {'symlink': tarfile.SYMTYPE, 'hardlink': tarfile.LNKTYPE,
                                   'fifo': tarfile.FIFOTYPE, 'directory': tarfile.DIRTYPE}[change]
                    member.linkname = '../outside' if change in ['symlink', 'hardlink'] else ''
                    member.size = 0
                elif change == 'size': member.size -= 1
                elif change == 'mode': member.mode = 0o644
                elif change == 'hash': entries[0] = (member, b'X' * len(content))
                elif change == 'absolute': member.name = '/tmp/outside'
                elif change == 'traversal': member.name = '../outside'
                with tarfile.open(archive, 'w') as tar:
                    for info, data in entries: tar.addfile(info, io.BytesIO(data))
                record['archive']['sha256'] = self.digest(archive)
                path.write_text(json.dumps(record))
                self.assertNotEqual(self.invoke().returncode, 0)
                self.assertFalse(self.output.exists())
        archive.write_bytes(original)
        self.assertNotEqual(self.invoke().returncode, 0)  # Last digest no longer matches.

    def test_metadata_resource_bounds_fail_before_archive_read(self):
        path = self.dirs[0] / 'provenance.json'; original = path.read_text()
        record = json.loads(original)
        for index in range(5):
            record['files'][f'assets/typescript/vendor/typescript/large{index}'] = dict(
                size=128 * 1024 * 1024, mode=0o644, sha256='a' * 64)
        path.write_text(json.dumps(record))
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exceeds bound', result.stderr)
        path.write_text(' ' * (2 * 1024 * 1024 + 1))
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exceeds bound', result.stderr)
        self.assertFalse(self.output.exists())

    def test_aliased_input_and_existing_output_are_rejected(self):
        archive = self.dirs[0] / 'installation.tar'; saved = archive.with_suffix('.saved')
        archive.rename(saved); archive.symlink_to(saved)
        self.assertNotEqual(self.invoke().returncode, 0)
        archive.unlink(); saved.rename(archive)
        self.output.mkdir(); marker = self.output / 'keep'; marker.write_text('owned by caller')
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(marker.read_text(), 'owned by caller')

    def test_pack_verification_checks_every_member_and_records_sizes(self):
        package = self.root / 'package'; package.mkdir()
        (package / 'package.json').write_text(json.dumps({'private': True, 'name': 'fixture'}))
        for target, (_, _, executable, bridge) in TARGETS.items():
            for name in [f'bin/{target}/{executable}', f'native/{target}/{bridge}']:
                path = package / name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'nonexecuted fixture'); path.chmod(0o755)
        packed = self.root / 'packed'; packed.mkdir()
        archive = packed / 'fixture.tgz'
        def prepare():
            paths = [p for p in package.rglob('*') if p.is_file() and p.name != 'manifest.json']
            hashes = {p.relative_to(package).as_posix(): self.digest(p) for p in paths}
            (package / 'manifest.json').write_text(json.dumps({'private': True, 'partial': False,
                                                             'targets': list(TARGETS), 'sha256': hashes}))
            paths.append(package / 'manifest.json')
            with tarfile.open(archive, 'w:gz') as tar:
                for path in paths: tar.add(path, arcname='package/' + path.relative_to(package).as_posix())
            files = [dict(path=p.relative_to(package).as_posix(), size=p.stat().st_size) for p in paths]
            (packed / 'npm-pack.json').write_text(json.dumps([dict(filename='fixture.tgz',
                size=archive.stat().st_size, unpackedSize=sum(f['size'] for f in files), files=files)]))
        def invoke():
            return subprocess.run([sys.executable, str(CLI), 'verify-pack', '--package', str(package),
                                     '--packed-directory', str(packed)], capture_output=True, text=True)
        prepare(); result = invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads((packed / 'packed-evidence.json').read_text())
        self.assertEqual(evidence['sha256'], self.digest(archive))
        self.assertEqual(evidence['files'], 8)
        self.assertEqual(evidence['compressed_bytes'], archive.stat().st_size)
        (packed / 'packed-evidence.json').unlink()
        original = archive.read_bytes()
        original_listing = (packed / 'npm-pack.json').read_text()
        for damage in ['crc', 'truncated', 'oversized_metadata']:
            with self.subTest(gzip_damage=damage):
                if damage == 'crc':
                    damaged = bytearray(original); damaged[-8] ^= 1
                    archive.write_bytes(damaged)
                elif damage == 'truncated':
                    archive.write_bytes(original[:-8])
                else:
                    header = tarfile.TarInfo('oversized-global-metadata')
                    header.type = tarfile.XGLTYPE; header.size = 17 * 1024 * 1024
                    with gzip.open(archive, 'wb') as stream:
                        stream.write(header.tobuf())
                        for _ in range(17): stream.write(b'\0' * (1024 * 1024))
                        stream.write(gzip.decompress(original))
                listing = json.loads(original_listing)
                listing[0]['size'] = archive.stat().st_size
                (packed / 'npm-pack.json').write_text(json.dumps(listing))
                try:
                    result = invoke()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertFalse((packed / 'packed-evidence.json').exists())
                finally:
                    (packed / 'packed-evidence.json').unlink(missing_ok=True)
        archive.write_bytes(original)
        (packed / 'npm-pack.json').write_text(original_listing)
        with tarfile.open(archive, 'r:gz') as tar:
            entries = [(m, tar.extractfile(m).read()) for m in tar]
        for change in ['hash', 'duplicate', 'mode']:
            import copy
            changed = copy.deepcopy(entries)
            if change == 'hash': changed[0] = (changed[0][0], b'X' * len(changed[0][1]))
            elif change == 'duplicate': changed.append(changed[0])
            else:
                next(m for m, _ in changed if m.name == 'package/bin/linux-x64/archway').mode = 0o644
            with tarfile.open(archive, 'w:gz') as tar:
                for member, data in changed: tar.addfile(member, io.BytesIO(data))
            self.assertNotEqual(invoke().returncode, 0)
            self.assertFalse((packed / 'packed-evidence.json').exists())
        archive.write_bytes(original)
        listing = json.loads((packed / 'npm-pack.json').read_text())
        listing[0]['files'].append(listing[0]['files'][0])
        (packed / 'npm-pack.json').write_text(json.dumps(listing))
        self.assertNotEqual(invoke().returncode, 0)
        (package / 'bin/macos-arm64/archway').unlink(); prepare()
        self.assertNotEqual(invoke().returncode, 0, 'Missing native payload must fail')
        self.assertFalse((packed / 'packed-evidence.json').exists())

    def test_three_targets_preserve_payload_modes_and_share_assets_once(self):
        before = {str(p): self.digest(p) for d in self.dirs for p in d.iterdir()}
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        installation = self.output / 'installation'
        self.assertEqual(len(list(installation.rglob('helper.cjs'))), 1)
        self.assertEqual((installation / 'assets/typescript/helper.cjs').read_bytes(), b'shared asset')
        self.assertEqual((installation / 'bin/linux-x64/archway').stat().st_mode & 0o777, 0o755)
        self.assertEqual({p.name for p in (installation / 'bin').iterdir()}, set(TARGETS))
        self.assertEqual(len(list((self.output / 'provenance').glob('*.json'))), 3)
        self.assertEqual(before, {str(p): self.digest(p) for d in self.dirs for p in d.iterdir()})


if __name__ == '__main__':
    unittest.main()
