from pathlib import Path
import tempfile
import unittest

from long_path_fixture import fixture_path, remove_fixture_tree


class LongPathFixtureTest(unittest.TestCase):
    def test_windows_extended_drive_and_unc_paths(self):
        self.assertEqual(str(fixture_path(r'C:\fixture\deep', windows=True)), r'\\?\C:\fixture\deep')
        self.assertEqual(str(fixture_path(r'\\server\share\deep', windows=True)), r'\\?\UNC\server\share\deep')
        self.assertEqual(str(fixture_path(r'\\?\C:\fixture', windows=True)), r'\\?\C:\fixture')
        with self.assertRaises(ValueError):
            fixture_path('relative', windows=True)

    def test_native_long_path_creation_rename_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            tree = Path(temp) / 'corpus'
            path = tree / ('x' * 150) / ('y' * 150) / ('z' * 150) / 'file.ts'
            native = fixture_path(path)
            native.parent.mkdir(parents=True)
            native.write_bytes(b'export {};')
            renamed = fixture_path(path.with_name('renamed.ts'))
            native.rename(renamed)
            self.assertEqual(renamed.read_bytes(), b'export {};')
            remove_fixture_tree(tree)
            self.assertFalse(tree.exists())


if __name__ == '__main__':
    unittest.main()
