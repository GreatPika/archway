"""Real private writer/reader subprocess tests; tiny stages are only controls."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tool/ci/pub_stage_transport.py'


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ArchiveControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.source = self.base / 'checkout'
        self.source.mkdir()
        for name in ['pubspec.lock', 'assets/typescript/package-lock.json']:
            path = self.source / name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture lock')
        env = {key: value for key, value in os.environ.items() if not key.upper().startswith('GIT_')}
        env.update({'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull})
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.source), *args], env=env).decode().strip()
        git('init', '-q'); git('add', '.')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgSign=false', 'commit', '-qm', 'Fixture')
        self.commit = git('rev-parse', 'HEAD')
        identity = {'commit': self.commit, 'tree': git('rev-parse', 'HEAD^{tree}'),
                    'lockfile_sha256': {name: digest(b'fixture lock') for name in
                    ['pubspec.lock', 'assets/typescript/package-lock.json']}}
        evidence = self.base / 'evidence'
        stage = evidence / 'pub source café'
        names = ['bin/archway.dart', 'bin/setup.dart', 'native/linux-x64/libarchway_io.so',
                 'native/macos-arm64/libarchway_io.dylib', 'native/windows-x64/archway_io.dll',
                 'assets/typescript/vendor/typescript/lib/lib.es2022.d.ts',
                 'assets/typescript/vendor/typescript/LICENSE.txt', 'assets/typescript/vendor/yaml/LICENSE',
                 'assets/typescript/licenses/pnpm-MIT.txt', 'assets/typescript/licenses/yaml-ISC.txt']
        files = {}
        for name in names + ['pubspec.yaml']:
            path = stage / name; path.parent.mkdir(parents=True, exist_ok=True)
            data = (b'name: archway\nversion: 0.1.0\npublish_to: none\nexecutables:\n  archway:\n'
                    if name == 'pubspec.yaml' else b'inert fixture')
            path.write_bytes(data); files[name] = digest(data)
        manifest = {'private': True, 'partial': False,
                    'targets': ['linux-x64', 'macos-arm64', 'windows-x64'],
                    'versions': {'archway': '0.1.0', 'dart': '3.13.3', 'node': '24.21.0',
                                 'typescript': '5.9.3', 'yaml': '2.8.1'}, 'sha256': files.copy()}
        (stage / 'manifest.json').write_text(json.dumps(manifest))
        files['manifest.json'] = digest((stage / 'manifest.json').read_bytes())
        self.stage_digest = digest(json.dumps(files, sort_keys=True).encode())
        (evidence / 'stage-identity.json').write_text(json.dumps({'source': identity, 'files': files,
            'file_set_sha256': self.stage_digest, 'scope': 'fixture only', 'transport_audit': {}}))
        (evidence / 'report.json').write_text(json.dumps({'source': identity, 'files': len(files),
            'file_set_sha256': self.stage_digest}))
        output = self.base / 'transport'
        result = subprocess.run([sys.executable, str(SCRIPT), 'write', '--stage-evidence', str(evidence),
            '--source', str(self.source), '--expected-source', self.commit, '--run-id', '123',
            '--run-attempt', '1', '--output', str(output)], capture_output=True, check=True)
        self.expected = json.loads(result.stdout)
        self.archive = output / 'pub-stage.tar.gz'
        self.received = self.base / 'received'

    def receive(self, expected=None, attempt='1'):
        return subprocess.run([sys.executable, str(SCRIPT), 'read', '--archive', str(self.archive),
            '--expected-json', json.dumps(expected or self.expected), '--source', str(self.source),
            '--expected-source', self.commit, '--run-id', '123', '--run-attempt', attempt,
            '--output', str(self.received)], capture_output=True, timeout=20)

    def rejected(self, reason, **kwargs):
        result = self.receive(**kwargs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason.encode(), result.stderr)
        self.assertFalse(self.received.exists())
        self.assertEqual(list(self.base.glob('.pub-receive-*')), [])

    def rewrite(self, mutation, trailing=b''):
        with tarfile.open(self.archive, 'r:gz') as stream:
            members = [(member, stream.extractfile(member).read()) for member in stream]
        members = mutation(members)
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w', format=tarfile.USTAR_FORMAT) as stream:
            for member, payload in members:
                stream.addfile(member, io.BytesIO(payload) if member.isreg() else None)
        self.archive.write_bytes(gzip.compress(data.getvalue() + trailing))
        self.expected['archive'] = {'size': self.archive.stat().st_size,
                                    'sha256': digest(self.archive.read_bytes())}

    def test_round_trip_compares_bytes_not_source_platform_modes(self):
        def modes(members):
            for member, _ in members: member.mode = 0o755
            return members
        self.rewrite(modes)
        result = self.receive()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.received / 'pub source café/bin/archway.dart').read_bytes(), b'inert fixture')

    def test_current_attempt_cannot_accept_previous_attempt(self):
        self.rejected('current source/run/attempt', attempt='2')

    def test_checkout_lock_changes_are_rejected(self):
        (self.source / 'pubspec.lock').write_text('changed')
        self.rejected('clean tracked sources')

    def test_missing_member_is_rejected(self):
        self.rewrite(lambda members: members[1:])
        self.rejected('Transport file set differs')

    def test_duplicate_member_is_rejected(self):
        self.rewrite(lambda members: members + [members[0]])
        self.rejected('Unexpected transport member')

    def test_traversal_is_rejected_before_extraction(self):
        def traversal(members):
            members[0][0].name = '../escaped'; return members
        self.rewrite(traversal)
        self.rejected('Unexpected transport member')
        self.assertFalse((self.base / 'escaped').exists())

    def test_link_and_special_members_are_rejected(self):
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.GNUTYPE_SPARSE]:
            with self.subTest(kind=kind):
                original = self.archive.read_bytes()
                def special(members):
                    member = members[0][0]; member.type = kind; member.size = 0
                    member.linkname = 'outside' if kind in [tarfile.SYMTYPE, tarfile.LNKTYPE] else ''
                    return [(member, b''), *members[1:]]
                self.rewrite(special)
                self.rejected('Unexpected transport member')
                self.archive.write_bytes(original)

    def test_tail_after_tar_end_marker_is_rejected(self):
        self.rewrite(lambda members: members, trailing=b'hidden content'.ljust(512, b'\0'))
        self.rejected('Nonzero data after tar end marker')

    def test_rehashed_archive_cannot_change_staged_file_hash(self):
        def corrupt(members):
            member, data = members[0]
            return [(member, b'X' * len(data)), *members[1:]]
        self.rewrite(corrupt)
        self.rejected('Transport staged bytes differ')

    def test_corrupt_gzip_trailer_is_rejected(self):
        data = bytearray(self.archive.read_bytes()); data[-8] ^= 1
        self.archive.write_bytes(data)
        self.expected['archive']['sha256'] = digest(data)
        self.rejected('CRC check failed')

    def test_oversized_declared_member_is_rejected(self):
        header = tarfile.TarInfo('pub source café/oversized')
        header.size = 128 * 1024 * 1024 + 1
        header.mode = 0o644
        self.archive.write_bytes(gzip.compress(header.tobuf(format=tarfile.USTAR_FORMAT) + b'\0' * 1024))
        self.expected['archive'] = {'size': self.archive.stat().st_size,
                                    'sha256': digest(self.archive.read_bytes())}
        self.rejected('Unexpected transport member')

    def test_member_count_is_bounded_before_extraction(self):
        def many(members):
            for index in range(4099):
                member = tarfile.TarInfo('pub source café/extra-' + str(index))
                member.mode = 0o644
                members.append((member, b''))
            return members
        self.rewrite(many)
        self.rejected('Unexpected transport member')

    def test_duplicate_json_metadata_is_rejected(self):
        def duplicate(members):
            result = []
            for member, payload in members:
                if member.name == 'report.json':
                    payload = b'{"source": {}, "source": {}}'
                    member.size = len(payload)
                result.append((member, payload))
            return result
        self.rewrite(duplicate)
        self.rejected('Duplicate JSON key')

    def test_missing_tar_end_markers_are_rejected(self):
        raw = gzip.decompress(self.archive.read_bytes())
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as stream:
            last = stream.getmembers()[-1]
        end = last.offset_data + ((last.size + 511) // 512) * 512
        self.archive.write_bytes(gzip.compress(raw[:end]))
        self.expected['archive'] = {'size': self.archive.stat().st_size,
                                    'sha256': digest(self.archive.read_bytes())}
        self.rejected('Missing tar end markers')


if __name__ == '__main__':
    unittest.main()
