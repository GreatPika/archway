"""Build-input seam; does not establish Windows lifecycle/GUI acceptance."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / 'tool/installers/windows/prepare.py'


class WindowsInstallerPreparation(unittest.TestCase):
    def test_prepares_complete_payload_without_changing_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = root / 'payload'
            (payload / 'bin/windows-x64').mkdir(parents=True)
            (payload / 'bin/windows-x64/archway.exe').write_bytes(b'fixture only')
            (payload / 'LICENSE').write_text('license')
            (payload / 'example..txt').write_text('valid dotted basename')
            files = {str(p.relative_to(payload)).replace('\\', '/'): {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'size': p.stat().st_size, 'mode': 420} for p in payload.rglob('*') if p.is_file()}
            (payload / 'manifest.json').write_text(json.dumps({'target': 'windows-x64', 'files': files}))
            output = root / 'prepared'
            result = subprocess.run([sys.executable, str(PREPARE), str(payload),
                                     str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((payload / 'LICENSE').read_text(), 'license')
            self.assertEqual(len(list(payload.rglob('*'))), 6)
            entries = (output / 'owned-files.txt').read_text().splitlines()
            self.assertEqual(len(entries), 4)
            self.assertEqual(entries[0].split('\t')[1], 'LICENSE')
            self.assertIn('bin\\windows-x64\\archway.exe',
                          (output / 'owned-files.txt').read_text())
            self.assertTrue((output / 'archway.iss').is_file())
            self.assertIn('example..txt', (output / 'owned-files.txt').read_text())


    def test_rejects_case_aliased_windows_directories_before_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = root / 'payload'
            for name in ('bin/windows-x64/archway.exe', 'Assets/a', 'assets/b'):
                path = payload / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            files = {p.relative_to(payload).as_posix(): {
                'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                'size': p.stat().st_size} for p in payload.rglob('*') if p.is_file()}
            (payload / 'manifest.json').write_text(json.dumps({
                'target': 'windows-x64', 'files': files}))
            result = subprocess.run([sys.executable, str(PREPARE), str(payload),
                                     str(root / 'out')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'out').exists())

    def test_rejects_output_inside_or_aliased_into_payload_without_changes(self):
        for aliased in (False, True):
            with self.subTest(aliased=aliased), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                payload = root / 'payload'
                binary = payload / 'bin/windows-x64/archway.exe'
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b'fixture')
                (payload / 'manifest.json').write_text(json.dumps({
                    'target': 'windows-x64', 'files': {
                        'bin/windows-x64/archway.exe': {
                            'sha256': hashlib.sha256(b'fixture').hexdigest(), 'size': 7}}}))
                before = {p.relative_to(payload).as_posix(): p.read_bytes()
                          for p in payload.rglob('*') if p.is_file()}
                parent = payload
                if aliased:
                    parent = root / 'alias'
                    parent.symlink_to(payload, target_is_directory=True)
                result = subprocess.run([sys.executable, str(PREPARE), str(payload),
                                         str(parent / 'new-output')],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(before, {p.relative_to(payload).as_posix(): p.read_bytes()
                                         for p in payload.rglob('*') if p.is_file()})
                self.assertFalse((payload / 'new-output').exists())

if __name__ == '__main__':
    unittest.main()
