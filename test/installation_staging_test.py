import tempfile
import unittest
from pathlib import Path

from installation_staging import stage_installation


class InstallationStagingTest(unittest.TestCase):
    def test_copies_actual_windows_archive_layout(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'
            executable = source / 'bin/windows-x64/archway.exe'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'actual executable')
            for directory in ['native/windows-x64', 'assets/typescript']:
                (source / directory).mkdir(parents=True)
                (source / directory / 'fixture').write_bytes(b'asset')
            staged = stage_installation(executable, root / 'relocated café')
            self.assertEqual(staged.relative_to(root / 'relocated café'),
                             Path('bin/windows-x64/archway.exe'))
            self.assertEqual(staged.read_bytes(), b'actual executable')
            self.assertEqual((root / 'relocated café/native/windows-x64/fixture').read_bytes(), b'asset')

    def test_rejects_unrecognized_or_mismatched_layout(self):
        for relative in ['bin/windows-x64/archway', 'bin/linux-x64/archway.exe',
                         'bin/unknown/archway']:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temp:
                executable = Path(temp) / 'source' / relative
                executable.parent.mkdir(parents=True)
                executable.touch()
                with self.assertRaises(AssertionError):
                    stage_installation(executable, Path(temp) / 'destination')
                self.assertFalse((Path(temp) / 'destination').exists())

    def test_copies_universal_macos_archive_without_relabeling(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'source'
            executable = source / 'bin/macos-universal/archway'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'universal binary')
            (source / 'native').mkdir()
            (source / 'assets').mkdir()
            staged = stage_installation(executable, Path(temp) / 'destination')
            self.assertEqual(staged.relative_to(Path(temp) / 'destination'),
                             Path('bin/macos-universal/archway'))
            self.assertEqual(staged.read_bytes(), b'universal binary')


if __name__ == '__main__':
    unittest.main()
