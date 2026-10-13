import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from node_package_fixture_support import extract_node_fixture


class NodePackageFixtureTest(unittest.TestCase):
    def test_directory_links_are_explicit_and_relative(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'fixture.tar'
            with tarfile.open(archive, 'w') as bundle:
                for name in ['store', 'store/package', 'node_modules']:
                    member = tarfile.TarInfo(name)
                    member.type = tarfile.DIRTYPE
                    member.mode = 0o755
                    bundle.addfile(member)
                member = tarfile.TarInfo('store/package/index.d.ts')
                member.size = 1
                bundle.addfile(member, io.BytesIO(b'x'))
                member = tarfile.TarInfo('node_modules/package')
                member.type = tarfile.SYMTYPE
                member.linkname = '../store/package'
                bundle.addfile(member)
            original = os.symlink
            with patch('node_package_fixture_support.os.symlink', wraps=original) as link:
                extract_node_fixture(archive, root / 'output')
            link.assert_called_once_with(
                os.path.join('..', 'store', 'package'),
                root / 'output/node_modules/package', target_is_directory=True)
            self.assertEqual((root / 'output/node_modules/package/index.d.ts').read_bytes(), b'x')

    def test_committed_archives_keep_links_and_hardlinks(self):
        archives = Path(__file__).parent / 'fixtures/node-packages'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            count = 0
            for name in ['prepared.tar.gz', 'addon.tar.gz', 'npm-override.tar.gz']:
                extract_node_fixture(archives / name, root)
                with tarfile.open(archives / name) as bundle:
                    for member in bundle:
                        target = root / member.name
                        if member.issym():
                            count += 1
                            self.assertTrue(target.is_symlink())
                            self.assertEqual(os.readlink(target), member.linkname.replace('/', os.sep))
                            self.assertTrue(target.is_dir())
                        elif member.islnk():
                            self.assertTrue(os.path.samefile(target, root / member.linkname))
                        elif member.isfile():
                            self.assertEqual(target.read_bytes(), bundle.extractfile(member).read())
                            if os.name != 'nt':
                                self.assertEqual(target.stat().st_mode & 0o777, member.mode & 0o777)
            self.assertEqual(count, 38)
            self.assertIn(b'6.1.0', (root / 'pnpm-registry/node_modules/ansi-regex/package.json').read_bytes())

    def test_escaping_link_is_rejected_before_extracting_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'escape.tar'
            with tarfile.open(archive, 'w') as bundle:
                member = tarfile.TarInfo('alias')
                member.type = tarfile.SYMTYPE
                member.linkname = '../outside'
                bundle.addfile(member)
            with self.assertRaises(ValueError):
                extract_node_fixture(archive, root / 'output')
            self.assertFalse((root / 'output').exists())

    def test_existing_destination_alias_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'outside').mkdir()
            (root / 'output').mkdir()
            os.symlink(str(root / 'outside'), root / 'output/store', target_is_directory=True)
            archive = root / 'fixture.tar'
            with tarfile.open(archive, 'w') as bundle:
                member = tarfile.TarInfo('store/file')
                member.size = 1
                bundle.addfile(member, io.BytesIO(b'x'))
            with self.assertRaises(ValueError):
                extract_node_fixture(archive, root / 'output')
            self.assertEqual(list((root / 'outside').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
