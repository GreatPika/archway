"""Keep the standalone stage verifier safe to import during unit discovery."""
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'test/pub_stage_identity_test.py'


class StageIdentityEntryTests(unittest.TestCase):
    def test_import_does_not_consume_arguments_or_invoke_verifier(self):
        with patch.object(sys, 'argv', ['unittest']), patch.object(subprocess, 'run') as run:
            namespace = runpy.run_path(str(PROBE))
        run.assert_not_called()
        self.assertTrue(callable(namespace['main']))

    def test_manual_entry_forwards_original_verifier_arguments(self):
        arguments = ['stage', 'source', 'combined', 'transports', 'source-commit']
        with patch.object(sys, 'argv', [str(PROBE), *arguments]), \
                patch.object(subprocess, 'run', side_effect=RuntimeError('verifier reached')) as run:
            with self.assertRaisesRegex(RuntimeError, 'verifier reached'):
                runpy.run_path(str(PROBE), run_name='__main__')
        run.assert_called_once_with([
            sys.executable, str(ROOT / 'tool/ci/verify_pub_stage.py'),
            '--stage', 'stage', '--source', 'source', '--combined', 'combined',
            '--transports', 'transports', '--expected-commit', 'source-commit'],
            capture_output=True, text=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
