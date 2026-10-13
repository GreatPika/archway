"""Bounded pub upload archive controls; no registry or runtime certification."""
import hashlib
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
import pub_stage_inventory as validation


class UploadArchive(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.archive = self.root / 'pub-package.tar.gz'
        self.payloads = {'pubspec.yaml': b'name: fixture\n', 'bin/main.dart': b'void main() {}\n'}
        self.files = {name: hashlib.sha256(data).hexdigest() for name, data in self.payloads.items()}

    def write_archive(self, extra=None):
        with tarfile.open(self.archive, 'w:gz', format=tarfile.USTAR_FORMAT) as stream:
            directory = tarfile.TarInfo('bin'); directory.type = tarfile.DIRTYPE
            directory.mode = 0o755; stream.addfile(directory)
            for name, data in self.payloads.items():
                member = tarfile.TarInfo(name); member.size = len(data); member.mode = 0o644
                stream.addfile(member, io.BytesIO(data))
            if extra:
                stream.addfile(extra, io.BytesIO(b'x' * extra.size))

    def test_extra_duplicate_traversal_and_link_entries_are_rejected_before_output(self):
        cases = [('unexpected', tarfile.REGTYPE), ('bin/main.dart', tarfile.REGTYPE),
                 ('../outside', tarfile.REGTYPE), ('link', tarfile.SYMTYPE)]
        for name, kind in cases:
            with self.subTest(name=name):
                extra = tarfile.TarInfo(name); extra.type = kind; extra.mode = 0o644
                if kind == tarfile.SYMTYPE:
                    extra.linkname = 'pubspec.yaml'
                self.write_archive(extra)
                output = self.root / 'received'
                with self.assertRaises(ValueError):
                    validation.inspect_upload_archive(self.archive, self.files, output)
                self.assertFalse(output.exists())

    def test_changed_missing_and_oversized_archive_bytes_are_rejected(self):
        self.write_archive()
        wrong = dict(self.files); wrong['pubspec.yaml'] = '0' * 64
        with self.assertRaises(ValueError):
            validation.inspect_upload_archive(self.archive, wrong)
        with self.assertRaises(ValueError):
            validation.inspect_upload_archive(self.archive, {**self.files, 'missing': '0' * 64})
        for constant in ['PUB_COMPRESSED_LIMIT', 'PUB_EXPANDED_LIMIT']:
            with self.subTest(constant=constant), patch.object(validation, constant, 10):
                with self.assertRaises(ValueError):
                    validation.inspect_upload_archive(self.archive, self.files)
        self.archive.write_bytes(self.archive.read_bytes()[:-4])
        with self.assertRaises((EOFError, ValueError)):
            validation.inspect_upload_archive(self.archive, self.files)

    def test_exact_file_bytes_and_pinned_directory_dialect_round_trip(self):
        self.write_archive()
        output = self.root / 'received'
        proof = validation.inspect_upload_archive(self.archive, self.files, output)
        self.assertEqual(proof['sha256'], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        self.assertEqual(proof['size'], self.archive.stat().st_size)
        self.assertEqual(proof['unpacked_bytes'], sum(map(len, self.payloads.values())))
        self.assertEqual({p.relative_to(output).as_posix(): p.read_bytes()
                          for p in output.rglob('*') if p.is_file()}, self.payloads)


if __name__ == '__main__':
    unittest.main()
