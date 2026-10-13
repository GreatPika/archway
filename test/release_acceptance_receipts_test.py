"""Read-only acceptance-receipt validation; synthetic fixtures are never platform proof."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
from release_acceptance_receipts import validate_pub, validate_npm, validate_native
from release_receipt_fixtures import native_fixture, npm_fixture, pub_fixture


class ReceiptValidation(unittest.TestCase):
    def test_missing_expanded_proofs_are_rejected(self):
        for call in (lambda: validate_pub({}, Path('/missing'), 'linux-x64', ROOT),
                     lambda: validate_npm({}, 'local'),
                     lambda: validate_native({}, Path('/missing'), Path('/missing'), {})):
            with self.assertRaises((ValueError, KeyError, TypeError)):
                call()

    def test_native_exact_inventory_source_fixture_relocation_receipts_and_logs(self):
        source = {'commit': 'a' * 40, 'tree': 'b' * 40, 'lockfile_sha256': {}}
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            proof = {'target': 'linux-x64', **native_fixture(root, 'linux-x64', source)}
            report = root / 'report.json'
            validate_native(proof, report, root, source)
            mutations = [lambda p: p.update(acceptance=None),
                         lambda p: p['acceptance']['suites'].pop(),
                         lambda p: p['acceptance']['source'].update(commit='0' * 40),
                         lambda p: p['acceptance']['suites'][0].update(exit_code=1),
                         lambda p: p['acceptance']['suites'][0].update(timed_out=True),
                         lambda p: p['relocation'].update(original_removed=False),
                         lambda p: p['relocation'].update(executed=p['relocation']['extracted']),
                         lambda p: p['acceptance']['suites'][0]['command'].__setitem__(2, '/another/archway')]
            for index, mutate in enumerate(mutations):
                changed = copy.deepcopy(proof)
                mutate(changed)
                with self.subTest(index=index), self.assertRaises((ValueError, KeyError, TypeError)):
                    validate_native(changed, report, root, source)
            for suite in ('plan_query', 'check', 'dart_check', 'package_provenance'):
                changed = copy.deepcopy(proof)
                receipt = next(r for r in changed['acceptance']['suites'] if r['suite'] == suite)
                if suite == 'plan_query':
                    receipt['command'][1] = '/unrelated-harness/test/plan_query_process_smoke.py'
                else:
                    receipt['command'] = receipt['command'][:3]
                    if suite == 'dart_check':
                        receipt['command'].append('--existing-installation')
                original_path = root / 'acceptance' / (suite + '.json')
                original_receipt = original_path.read_bytes()
                original_path.write_text(json.dumps(receipt))
                with self.subTest(command=suite), self.assertRaises(ValueError):
                    validate_native(changed, report, root, source)
                original_path.write_bytes(original_receipt)
            changed = copy.deepcopy(proof)
            changed['acceptance']['fixtures']['manifest']['source'] = {'commit': '0' * 40}
            fixture = root / 'acceptance-fixtures.json'
            original_bytes = fixture.read_bytes()
            fixture.write_text(json.dumps(changed['acceptance']['fixtures']['manifest']))
            changed['acceptance']['fixtures']['sha256'] = hashlib.sha256(fixture.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):
                validate_native(changed, report, root, source)
            fixture.write_bytes(original_bytes)
            (root / 'acceptance/cli.stdout.log').write_text('changed bytes')
            with self.assertRaises(ValueError):
                validate_native(proof, report, root, source)

    def test_runtime_request_diagnostic_argument_is_bound_on_every_target(self):
        source = {'commit': 'a' * 40, 'tree': 'b' * 40, 'lockfile_sha256': {}}
        for target in ('linux-x64', 'macos-arm64', 'windows-x64'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                proof = {'target': target, **native_fixture(root, target, source)}
                report = root / 'report.json'
                validate_native(proof, report, root, source)
                for mutation in ('omitted', 'redirected'):
                    changed = copy.deepcopy(proof)
                    receipt = next(r for r in changed['acceptance']['suites']
                                   if r['suite'] == 'runtime_request')
                    if mutation == 'omitted':
                        receipt['command'].pop()
                    else:
                        receipt['command'][-1] += '.wrong'
                    # Keep the standalone receipt consistent, so rejection must
                    # come from the exact harness command contract.
                    receipt_path = root / 'acceptance/runtime_request.json'
                    original = receipt_path.read_bytes()
                    receipt_path.write_text(json.dumps(receipt))
                    try:
                        with self.subTest(mutation=mutation), self.assertRaisesRegex(
                                ValueError, 'full command differs'):
                            validate_native(changed, report, root, source)
                    finally:
                        receipt_path.write_bytes(original)

    def test_npm_all_asset_and_explicit_corpus_results_are_required(self):
        for route in ('local', 'global', 'cache'):
            value = npm_fixture(route)
            validate_npm(value, route)
            changed = copy.deepcopy(value)
            changed['asset_controls'].pop()
            with self.assertRaises(ValueError):
                validate_npm(changed, route)
            changed = copy.deepcopy(value)
            changed['asset_controls'][0]['exit'] = 0
            with self.assertRaises(ValueError):
                validate_npm(changed, route)
            changed = copy.deepcopy(value)
            changed['corpus_control']['applicable'] = not value['corpus_control']['applicable']
            with self.assertRaises(ValueError):
                validate_npm(changed, route)

    def test_synthetic_pub_outputs_pass_and_missing_failed_or_rehashed_wrong_json_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            artifact = Path(temp)
            proof = pub_fixture(artifact, 'linux-x64')
            validate_pub(proof, artifact, 'linux-x64', ROOT)
            for mutation in ('missing', 'failed', 'wrong-code', 'malformed'):
                changed = copy.deepcopy(proof)
                if mutation == 'missing':
                    changed['analysis']['cases'].pop()
                elif mutation == 'failed':
                    changed['analysis']['cases'][0]['exit'] = 2
                elif mutation == 'wrong-code':
                    changed['analysis']['cases'][6]['error'] = 'WRONG_CODE'
                else:
                    (artifact / 'analysis/missing-node.stdout.log').write_text('not json')
                    changed['analysis']['cases'][6]['stdout_sha256'] = hashlib.sha256(b'not json').hexdigest()
                with self.subTest(mutation=mutation), self.assertRaises((ValueError, KeyError, TypeError)):
                    validate_pub(changed, artifact, 'linux-x64', ROOT)


if __name__ == '__main__':
    unittest.main()
