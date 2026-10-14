"""Static native-host preparation wiring; real host runs remain mandatory."""
import ast
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflow(unittest.TestCase):
    def test_three_native_archive_consumers_require_pinned_preparation(self):
        raw = (ROOT / '.github/workflows/package-delivery-probe.yml').read_text()
        workflow = yaml.load(raw, Loader=yaml.BaseLoader)
        jobs = workflow['jobs']
        native = jobs['release-native']
        self.assertEqual(native['needs'], ['audit'])
        self.assertEqual(native['strategy']['fail-fast'], 'false')
        self.assertEqual({cell['target'] for cell in native['strategy']['matrix']['include']},
                         {'linux-x64', 'macos-arm64', 'windows-x64'})
        runs = '\n'.join(step.get('run', '') for step in native['steps'])
        self.assertIn('release_native_smoke.dart', runs)
        self.assertIn('"$NATIVE_DART" --suppress-analytics run tool/ci/release_native_smoke.dart', runs)
        controls = next(step['run'] for step in native['steps']
                        if 'fixture-controls.log' in step.get('run', ''))
        fixture_script = controls.split("<<'PYTHON'", 1)[1].split('\n', 1)[1].rsplit('PYTHON', 1)[0]
        preparation = ast.parse(fixture_script)
        unconditional = '\n'.join(ast.unparse(node) for node in preparation.body
                                  if not isinstance(node, ast.If))
        self.assertIn("'pub', 'get', '--enforce-lockfile'", unconditional)
        self.assertIn("'git', 'diff', '--exit-code', '--', 'pubspec.lock'", unconditional)
        self.assertIn('NATIVE_DART=', controls)
        self.assertIn("'GITHUB_ENV'", controls)
        self.assertIn('3.13.3', controls)
        self.assertLess(runs.index('--enforce-lockfile'), runs.index('release_native_smoke.dart'))
        self.assertIn('--ci-host', runs)
        self.assertIn('--installer-checks', runs)
        self.assertGreaterEqual(int(native['timeout-minutes']), 45)
        self.assertIn('prepare_native_acceptance.py', runs)
        self.assertIn("'jsonschema==4.26.0'", runs)
        self.assertLess(runs.index('prepare_native_acceptance.py'), runs.index('release_native_smoke.dart'))
        self.assertIn('--acceptance-fixtures "$RUNNER_TEMP/archway-native-fixtures/acceptance-fixtures.json"', runs)
        self.assertIn('--expected-commit "$GITHUB_SHA"', runs)
        downloads = [step['with']['name'] for step in native['steps']
                     if 'download-artifact@' in step.get('uses', '')]
        self.assertEqual(downloads, ['release-bundles-${{ github.run_id }}-${{ github.run_attempt }}'])



if __name__ == '__main__':
    unittest.main()
