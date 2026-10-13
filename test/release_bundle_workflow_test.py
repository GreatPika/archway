"""Static final-archive wiring; real native-host runs remain mandatory."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflow(unittest.TestCase):
    def test_one_producer_three_exact_archive_consumers_and_success_gated_finalize(self):
        raw = (ROOT / '.github/workflows/package-delivery-probe.yml').read_text()
        workflow = yaml.load(raw, Loader=yaml.BaseLoader)
        jobs = workflow['jobs']
        producer = '\n'.join(step.get('run', '') for step in jobs['audit']['steps'])
        self.assertEqual(producer.count('tool/release_bundles.py'), 1)
        self.assertLess(producer.index('combine_installations.py verify-pack'),
                        producer.index('tool/release_bundles.py'))
        self.assertIn('test -f LICENSE', producer)
        native = jobs['release-native']
        self.assertEqual(native['needs'], ['audit'])
        self.assertEqual(native['strategy']['fail-fast'], 'false')
        self.assertEqual({cell['target'] for cell in native['strategy']['matrix']['include']},
                         {'linux-x64', 'macos-arm64', 'windows-x64'})
        runs = '\n'.join(step.get('run', '') for step in native['steps'])
        self.assertIn('release_native_smoke.py', runs)
        self.assertIn('--ci-host', runs)
        self.assertIn('--installer-checks', runs)
        self.assertGreaterEqual(int(native['timeout-minutes']), 45)
        self.assertIn('prepare_native_acceptance.py', runs)
        self.assertIn("'jsonschema==4.26.0'", runs)
        self.assertLess(runs.index('prepare_native_acceptance.py'), runs.index('release_native_smoke.py'))
        self.assertIn('--acceptance-fixtures "$RUNNER_TEMP/archway-native-fixtures/acceptance-fixtures.json"', runs)
        self.assertGreaterEqual(int(native['timeout-minutes']), 25)
        self.assertIn('--expected-commit "$GITHUB_SHA"', runs)
        downloads = [step['with']['name'] for step in native['steps']
                     if 'download-artifact@' in step.get('uses', '')]
        self.assertEqual(downloads, ['release-bundles-${{ github.run_id }}-${{ github.run_attempt }}'])
        finalize = jobs['release-finalize']
        self.assertEqual(set(finalize['needs']), {'audit', 'release-native', 'npm-installed', 'pub-installed'})
        final_runs = '\n'.join(step.get('run', '') for step in finalize['steps'])
        self.assertIn('finalize_release_evidence.py', final_runs)
        self.assertIn('--run-id \"$GITHUB_RUN_ID\" --run-attempt \"$GITHUB_RUN_ATTEMPT\"', final_runs)
        self.assertIn('--expected-pub-transport-json \"$EXPECTED_PUB_TRANSPORT\"', final_runs)
        final_step = next(s for s in finalize['steps'] if 'finalize_release_evidence.py' in s.get('run', ''))
        self.assertEqual(final_step['env']['EXPECTED_PUB_TRANSPORT'], '${{ needs.audit.outputs.pub-transport }}')
        self.assertNotIn('release_bundles.py', final_runs)
        self.assertNotIn('continue-on-error', raw)
        self.assertEqual(workflow['permissions'], {'contents': 'read'})


if __name__ == '__main__':
    unittest.main()
