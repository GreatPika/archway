"""Static wiring and inert shell arguments only; never dispatch or validate a candidate."""
import json
import os
import shlex
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/package-delivery-probe.yml'


class RegistryWorkflow(unittest.TestCase):
    def test_boolean_intent_defaults_private_and_rejects_invalid_values(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        setting = workflow['on']['workflow_dispatch']['inputs']['registry-ready']
        self.assertEqual(setting['type'], 'boolean')
        self.assertEqual(setting['default'], 'false')
        self.assertEqual(workflow['env']['ARCHWAY_REGISTRY_READY'],
            "${{ github.event_name == 'workflow_dispatch' && toJSON(inputs.registry-ready) || 'false' }}")
        command = 'source tool/ci/registry_candidate_arguments.sh; python3 -c \'import json,sys; print(json.dumps(sys.argv[1:]))\' ${registry_args[@]+"${registry_args[@]}"}'
        for value, expected in [('false', []), ('true', ['--registry-ready'])]:
            result = subprocess.run(['bash', '-euc', command], cwd=ROOT,
                env={**os.environ, 'ARCHWAY_REGISTRY_READY': value}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), expected)
        for value in ['', 'TRUE', '1', 'null', '"true"', 'false; echo unsafe']:
            result = subprocess.run(['bash', '-euc', command], cwd=ROOT,
                env={**os.environ, 'ARCHWAY_REGISTRY_READY': value}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')

    def test_all_existing_owners_receive_the_same_explicit_intent(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        owners = ['tool/package_delivery.py npm', 'tool/ci/combine_installations.py verify-pack',
            'tool/release_bundles.py', 'test/pub_package_process_smoke.py',
            'test/pub_stage_identity_test.py', 'tool/ci/pub_stage_transport.py write',
            'tool/ci/npm_local_install_probe.py', 'tool/ci/pub_snapshot_probe.py',
            'tool/ci/finalize_release_evidence.dart']
        steps = [step for job in workflow['jobs'].values() for step in job.get('steps', [])]
        for owner in owners:
            matches = [step for step in steps if owner in step.get('run', '')]
            self.assertEqual(len(matches), 1, owner)
            script = matches[0]['run']
            self.assertIn('source tool/ci/registry_candidate_arguments.sh', script)
            line = next(line for line in script.replace('\\\n', ' ').splitlines() if owner in line)
            self.assertIn('${pub_args[@]+${pub_args[@]}}' if owner == 'test/pub_package_process_smoke.py'
                          else '${registry_args[@]+${registry_args[@]}}', shlex.split(line), owner)
        producer = next(step for step in steps if step.get('id') == 'pub-transport')['run']
        self.assertIn('pub_args=(${registry_args[@]+"${registry_args[@]}"})', producer)
        self.assertIn('if [[ "$ARCHWAY_REGISTRY_READY" == true ]]; then', producer)
        self.assertIn('pub_args+=(--prepared-cache "$PUB_PREPARED_CACHE")', producer)

    def test_candidate_raw_evidence_is_retained_in_existing_producer_artifact(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        steps = workflow['jobs']['audit']['steps']
        retained = next(step for step in steps if step.get('name') ==
                        'Retain bounded pub producer evidence even on failure')
        self.assertEqual(retained['if'], 'always()')
        paths = retained['with']['path'].splitlines()
        prefix = '${{ runner.temp }}/archway-pub-stage/'
        for name in ['stage-identity.json', 'dry-run-command.json', 'dry-run-status.json',
                     'dry-run-stdout.log', 'dry-run-stderr.log', 'archive-export-command.json',
                     'archive-export-status.json', 'archive-export-stdout.log', 'archive-export-stderr.log']:
            self.assertIn(prefix + name, paths)
        setup = next(step for step in steps if step.get('name') ==
                     'Prepare explicit Python and official pinned pub producer Dart')['run']
        self.assertIn('setup_args=()', setup)
        self.assertIn('if [[ "$ARCHWAY_REGISTRY_READY" == true ]]; then', setup)
        self.assertIn('setup_args+=(--prepare-cache)', setup)
        self.assertIn('${setup_args[@]+"${setup_args[@]}"}', setup)


if __name__ == '__main__':
    unittest.main()
