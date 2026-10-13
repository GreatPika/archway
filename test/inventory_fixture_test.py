"""Fixture boundary checks; Windows metadata is simulated, not native evidence."""
import unittest
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
from inventory_fixture import inventory_kind


class Entry:
    def is_symlink(self):
        return False

    def is_file(self, *, follow_symlinks):
        assert not follow_symlinks
        return False

    def is_dir(self, *, follow_symlinks):
        assert not follow_symlinks
        return True

    def stat(self, *, follow_symlinks):
        assert not follow_symlinks
        return SimpleNamespace(st_file_attributes=0x410,
                               st_reparse_tag=0xA0000003)


class InventoryFixtureTest(unittest.TestCase):
    def test_windows_junction_is_an_alias_in_inventory(self):
        # IO_REPARSE_TAG_MOUNT_POINT + DIRECTORY | REPARSE_POINT.
        # Dart 3.13.3 FileSystemEntity.type(followLinks:false) reports link.
        self.assertEqual(inventory_kind(Entry()), 'symlink')

    def test_windows_unix_socket_reparse_tag_is_other(self):
        entry = Entry()
        entry.stat = lambda **kwargs: SimpleNamespace(
            st_file_attributes=0x400, st_reparse_tag=0x80000023)
        self.assertEqual(inventory_kind(entry), 'other')

    def test_other_windows_reparse_tags_remain_aliases(self):
        for tag in [0xA000000C, 0x8000001B]:
            with self.subTest(tag=tag):
                entry = Entry()
                entry.stat = lambda **kwargs: SimpleNamespace(
                    st_file_attributes=0x400, st_reparse_tag=tag)
                self.assertEqual(inventory_kind(entry), 'symlink')

    def test_ordinary_entries_keep_their_types(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'directory').mkdir()
            (root / 'file').write_text('content')
            with os.scandir(root) as entries:
                actual = {entry.name: inventory_kind(entry) for entry in entries}
            self.assertEqual(actual, {'directory': 'directory', 'file': 'file'})


if __name__ == '__main__':
    unittest.main()
