"""OS-boundary controls for observational Windows pub exit diagnostics."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from pub_snapshot_analysis import diagnose_windows_exit


class ExitDiagnosticTests(unittest.TestCase):
    def test_same_check_and_environment_reach_both_routes_without_file_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = root / 'archway.bat'
            launcher.write_bytes(b'original launcher')
            snapshot = root / 'global_packages/archway/bin/archway.dart-3.13.3.snapshot'
            snapshot.parent.mkdir(parents=True)
            snapshot.write_bytes(b'original snapshot')
            before = {p: p.read_bytes() for p in (launcher, snapshot)}
            env = {'PATH': 'pinned path', 'PUB_CACHE': str(root)}
            args = ['--root', str(root / 'project café'), 'check']
            response = subprocess.CompletedProcess([], 2, b'{"exit_code":2}\n', b'')
            with patch('pub_snapshot_analysis.shutil.which', return_value='pinned-dart'), \
                    patch('pub_snapshot_analysis.command', return_value='cmd fixture') as command, \
                    patch('pub_snapshot_analysis.subprocess.run', return_value=response) as run:
                diagnose_windows_exit(launcher, args, root, env, root)
            direct = ['pinned-dart', str(snapshot), *args]
            command.assert_called_once_with(direct)
            self.assertEqual([c.args[0] for c in run.call_args_list], [direct, 'cmd fixture'])
            for call in run.call_args_list:
                self.assertEqual(call.kwargs, dict(cwd=root, env=env, capture_output=True, timeout=30))
            report = json.loads((root / 'exit-mismatch.log').read_text())
            self.assertEqual([r['exit'] for r in report['routes']], [2, 2])
            self.assertTrue(report['unchanged'])
            self.assertEqual(report['original_sha256'], {
                str(p): hashlib.sha256(data).hexdigest() for p, data in before.items()})
            self.assertEqual({p: p.read_bytes() for p in before}, before)

    def test_missing_dart_does_not_attempt_execution(self):
        with patch('pub_snapshot_analysis.shutil.which', return_value=None), \
                patch('pub_snapshot_analysis.subprocess.run') as run:
            with self.assertRaisesRegex(ValueError, 'pinned Dart is missing'):
                diagnose_windows_exit(Path('unused'), [], Path('unused'), {'PATH': ''}, Path('unused'))
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
