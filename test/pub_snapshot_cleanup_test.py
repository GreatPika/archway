"""Disposable fixture deletion controls; native Windows acceptance stays separate."""
import errno
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from pub_snapshot_probe import remove_disposable_source


class DisposableSourceCleanupTests(unittest.TestCase):
    def test_real_read_only_file_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'disposable Git source café'
            source.mkdir()
            obj = source / 'object'
            obj.write_bytes(b'fixture')
            obj.chmod(stat.S_IRUSR)
            try:
                remove_disposable_source(source)
                self.assertFalse(source.exists())
            finally:
                if obj.exists():
                    obj.chmod(stat.S_IRUSR | stat.S_IWUSR)

    def test_directory_permission_failure_does_not_change_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'disposable Git source café'
            source.mkdir()
            with patch('os.rmdir', side_effect=PermissionError(errno.EACCES, 'denied')), \
                    patch('os.chmod') as chmod:
                with self.assertRaises(PermissionError):
                    remove_disposable_source(source)
                chmod.assert_not_called()
            self.assertTrue(source.is_dir())

    @unittest.skipIf(os.name == 'nt', 'Link creation may require Windows privilege')
    def test_source_symlink_cannot_change_or_delete_external_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'original source'
            target.mkdir()
            obj = target / 'object'
            obj.write_bytes(b'unchanged')
            obj.chmod(stat.S_IRUSR)
            mode = obj.stat().st_mode
            source = root / 'disposable Git source café'
            source.symlink_to(target, target_is_directory=True)
            with self.assertRaises(OSError):
                remove_disposable_source(source)
            self.assertEqual(obj.read_bytes(), b'unchanged')
            self.assertEqual(obj.stat().st_mode, mode)

    def test_unrelated_errors_and_failed_retry_are_fatal(self):
        for mode, error, expected_attempts in [
            (stat.S_IRUSR | stat.S_IWUSR, PermissionError(errno.EACCES, 'denied'), 1),
            (stat.S_IRUSR, OSError(errno.EIO, 'I/O error'), 1),
            (stat.S_IRUSR, PermissionError(errno.EACCES, 'still denied'), 2),
        ]:
            with self.subTest(mode=mode, error=error), tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / 'disposable Git source café'
                source.mkdir()
                obj = source / 'object'
                obj.write_bytes(b'fixture')
                obj.chmod(mode)
                try:
                    with patch('os.unlink', side_effect=error) as unlink:
                        with self.assertRaises(type(error)):
                            remove_disposable_source(source)
                    self.assertEqual(unlink.call_count, expected_attempts)
                    self.assertTrue(obj.exists())
                    self.assertEqual(obj.read_bytes(), b'fixture')
                    if expected_attempts == 1:
                        self.assertEqual(bool(obj.stat().st_mode & stat.S_IWUSR),
                                         bool(mode & stat.S_IWUSR))
                finally:
                    obj.chmod(stat.S_IRUSR | stat.S_IWUSR)

    def test_read_only_git_object_is_removed_without_touching_neighbor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'disposable Git source café'
            obj = source / '.git/objects/00/object'
            obj.parent.mkdir(parents=True)
            obj.write_bytes(b'fixture Git object')
            obj.chmod(stat.S_IRUSR)
            neighbor = root / 'original source'
            neighbor.write_bytes(b'unchanged')
            neighbor.chmod(stat.S_IRUSR)
            original_mode = neighbor.stat().st_mode
            unlink = os.unlink
            attempts = []

            def windows_unlink(path, *args, **kwargs):
                # Inject Windows' read-only-file behavior at the OS boundary;
                # all traversal, chmod and successful deletion remain real.
                if Path(path).name == obj.name:
                    attempts.append(str(path))
                    if not obj.stat().st_mode & stat.S_IWUSR:
                        raise PermissionError(errno.EACCES, 'Access is denied', str(obj))
                return unlink(path, *args, **kwargs)

            try:
                with patch('os.unlink', side_effect=windows_unlink):
                    remove_disposable_source(source)
                self.assertFalse(source.exists())
                self.assertEqual(len(attempts), 2)
                self.assertEqual(neighbor.read_bytes(), b'unchanged')
                self.assertEqual(neighbor.stat().st_mode, original_mode)
            finally:
                neighbor.chmod(stat.S_IRUSR | stat.S_IWUSR)
                if obj.exists():
                    obj.chmod(stat.S_IRUSR | stat.S_IWUSR)


if __name__ == '__main__':
    unittest.main()
