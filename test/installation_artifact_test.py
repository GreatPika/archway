"""Bounded filesystem controls; genuine CLI acceptance runs separately."""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from installation_artifact import export_installation, _round_trip, source_identity, runtime_version


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.bundle = self.base / 'relocated ü installation'
        self.binary = self.bundle / 'bin/linux-x64/archway'
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b'hello\n')
        self.binary.chmod(0o751)
        self.destination = self.base / 'artifact'
        self.expected = {'bin/linux-x64/archway'}

    def export(self, verify):
        return export_installation(self.bundle, self.destination,
                                   self.expected, {'target': 'linux-x64'}, verify)

    @unittest.skipIf(os.name == 'nt', 'Unix assembler PATH/cwd semantics')
    def test_runtime_identity_uses_assembler_cwd_for_relative_path(self):
        caller = self.base / 'caller'
        repo = self.base / 'repository'
        for directory, identity in [(caller, 'caller runtime'), (repo, 'build runtime')]:
            compiler = directory / 'compiler/runtime'
            compiler.parent.mkdir(parents=True)
            compiler.write_text('#!/bin/sh\nprintf "' + identity + '\\n"\n')
            compiler.chmod(0o755)
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(caller)
        with patch.dict(os.environ, {'PATH': 'compiler'}):
            self.assertEqual(runtime_version('runtime', repo), 'build runtime')

    def test_failed_transported_assertion_cleans_only_owned_staging(self):
        unrelated = self.base / '.archway-artifact-unrelated'
        unrelated.mkdir()
        def reject(*_):
            raise AssertionError('transport init failed')
        with self.assertRaisesRegex(AssertionError, 'transport init failed'):
            self.export(reject)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.base.glob('.archway-artifact-*')), [unrelated])

    @unittest.skipIf(os.name == 'nt', 'POSIX alias fixture')
    def test_dangling_destination_alias_is_refused(self):
        self.destination.symlink_to(self.base / 'absent')
        with self.assertRaises(FileExistsError):
            self.export(lambda *_: None)
        self.assertTrue(self.destination.is_symlink())

    @unittest.skipIf(os.name == 'nt', 'POSIX alias fixture')
    def test_source_alias_is_refused(self):
        self.binary.unlink()
        self.binary.symlink_to('/dev/null')
        with self.assertRaises(ValueError):
            self.export(lambda *_: None)
        self.assertFalse(self.destination.exists())

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'POSIX special entry fixture')
    def test_special_source_entry_is_refused(self):
        os.mkfifo(self.bundle / 'pipe')
        with self.assertRaises(ValueError):
            self.export(lambda *_: None)
        self.assertFalse(self.destination.exists())

    def test_unexpected_archive_members_are_refused(self):
        for name, kind in [('other', tarfile.REGTYPE),
                           ('../escape', tarfile.REGTYPE),
                           ('bin//linux-x64/archway', tarfile.REGTYPE),
                           ('bin/linux-x64/archway', tarfile.SYMTYPE),
                           ('bin/linux-x64/archway', tarfile.DIRTYPE)]:
            with self.subTest(name=name, kind=kind):
                archive = self.base / 'invalid.tar'
                with tarfile.open(archive, 'w') as stream:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.mode = 0o751
                    stream.addfile(member)
                with tempfile.TemporaryDirectory(dir=self.base) as temporary:
                    with self.assertRaises(ValueError):
                        _round_trip(archive, Path(temporary) / 'extracted', {
                            'bin/linux-x64/archway': {'size': 0, 'mode': 0o751}})
        self.assertFalse((self.base / 'escape').exists())

    def test_source_identity_requires_clean_tracked_commit(self):
        repo = self.base / 'repo'
        repo.mkdir()
        def git(*args):
            return subprocess.run(['git', '-C', str(repo), *args], check=True,
                                  capture_output=True, text=True).stdout.strip()
        git('init', '-q')
        (repo / 'assets/typescript').mkdir(parents=True)
        for name in ['pubspec.lock', 'assets/typescript/package-lock.json']:
            (repo / name).write_text('locked\n')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            'commit', '-qm', 'fixture')
        identity = source_identity(repo)
        self.assertEqual(identity['commit'], git('rev-parse', 'HEAD'))
        self.assertEqual(identity['tree'], git('rev-parse', 'HEAD^{tree}'))
        (repo / 'pubspec.lock').write_text('changed\n')
        with self.assertRaises(ValueError):
            source_identity(repo)

    def test_controlled_round_trip_rejects_duplicate_members(self):
        archive = self.base / 'duplicate.tar'
        with tarfile.open(archive, 'w') as stream:
            for _ in range(2):
                member = tarfile.TarInfo('bin/linux-x64/archway')
                member.size = 6
                member.mode = 0o751
                stream.addfile(member, io.BytesIO(b'hello\n'))
        with self.assertRaises(ValueError):
            _round_trip(archive, self.base / 'extracted', {
                'bin/linux-x64/archway': {'size': 6, 'mode': 0o751}})

    def test_unexpected_empty_directory_is_rejected(self):
        (self.bundle / 'unexpected').mkdir()
        with self.assertRaises(ValueError):
            self.export(lambda *_: None)
        self.assertFalse(self.destination.exists())

    def test_existing_destination_is_never_replaced(self):
        self.destination.mkdir()
        with self.assertRaises(FileExistsError):
            self.export(lambda *_: None)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertEqual(list(self.base.glob('.archway-artifact-*')), [])

    def test_transport_preserves_bytes_and_execute_mode_before_publication(self):
        def verify(extracted, base):
            self.assertFalse(self.destination.exists())
            self.assertEqual(list(base.iterdir()), [extracted])
            binary = extracted / 'bin/linux-x64/archway'
            self.assertEqual(binary.read_bytes(), b'hello\n')
            if os.name != 'nt':
                self.assertEqual(binary.stat().st_mode & 0o777, 0o751)
        self.export(verify)
        self.assertEqual(sorted(p.name for p in self.destination.iterdir()),
                         ['installation.tar', 'provenance.json'])
        provenance = json.loads((self.destination / 'provenance.json').read_text())
        self.assertEqual(provenance['files']['bin/linux-x64/archway']['sha256'],
                         '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03')
        archive = self.destination / 'installation.tar'
        self.assertEqual(provenance['archive']['sha256'],
                         hashlib.sha256(archive.read_bytes()).hexdigest())
        with tarfile.open(archive) as stream:
            self.assertEqual(stream.getnames(), ['bin/linux-x64/archway'])


if __name__ == '__main__':
    unittest.main()
