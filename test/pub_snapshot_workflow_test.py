"""Static CI mutation guards, not proof of native platform acceptance."""
from pathlib import Path
import unittest
import os
import subprocess
import tempfile
import shlex
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/package-delivery-probe.yml'


class PubWorkflowTests(unittest.TestCase):
    def test_one_same_source_stage_transport_has_current_attempt_identity(self):
        raw = WORKFLOW.read_text()
        jobs = yaml.load(raw, Loader=yaml.BaseLoader)['jobs']
        audit = jobs['audit']
        self.assertEqual(audit['outputs'], {
            'pub-transport': '${{ steps.pub-transport.outputs.identity }}'})
        runs = '\n'.join(s.get('run', '') for s in audit['steps'])
        self.assertEqual(runs.count('test/pub_package_process_smoke.py'), 1)
        self.assertEqual(runs.count('pub_stage_transport.py write'), 1)
        self.assertLess(runs.index('combine_installations.py combine'), runs.index('test/pub_package_process_smoke.py'))
        self.assertLess(runs.index('test/pub_package_process_smoke.py'), runs.index('pub_stage_transport.py write'))
        for required in ['"$PUB_DART" "$GITHUB_WORKSPACE" combined transports "$GITHUB_SHA"',
                         '--expected-source "$GITHUB_SHA"', '--run-id "$GITHUB_RUN_ID"',
                         '--run-attempt "$GITHUB_RUN_ATTEMPT"', '>> "$GITHUB_OUTPUT"']:
            self.assertIn(required, runs)
        upload = next(s for s in audit['steps'] if s.get('name') == 'Retain one verified private pub transport')
        self.assertEqual(upload['if'], 'success()')
        self.assertEqual(upload['with'], {
            'name': 'private-pub-stage-${{ github.run_id }}-${{ github.run_attempt }}',
            'path': '${{ runner.temp }}/archway-pub-transport/pub-stage.tar.gz',
            'retention-days': '1', 'if-no-files-found': 'error', 'compression-level': '0'})

    def test_linux_producer_checks_stage_mutations_before_transport_and_retains_log(self):
        raw = WORKFLOW.read_text()
        audit = yaml.load(raw, Loader=yaml.BaseLoader)['jobs']['audit']
        self.assertEqual(audit['runs-on'], 'ubuntu-24.04')
        producer = next(s for s in audit['steps'] if s.get('id') == 'pub-transport')
        self.assertEqual(producer['shell'], 'bash')
        commands = [shlex.split(line) for line in producer['run'].replace('\\\n', ' ').splitlines()]
        self.assertEqual(commands[0], ['set', '-euo', 'pipefail'])
        self.assertEqual(commands[1:6], [
            ['source', 'tool/ci/registry_candidate_arguments.sh'],
            ['pub_args=(${registry_args[@]+${registry_args[@]}})'],
            ['if', '[[', '$ARCHWAY_REGISTRY_READY', '==', 'true', ']];', 'then'],
            ['pub_args+=(--prepared-cache', '$PUB_PREPARED_CACHE)'], ['fi']])
        self.assertEqual(commands[6][:3], ['python', '-u', 'test/pub_package_process_smoke.py'])
        self.assertEqual(commands[7], [
            'python', '-u', 'test/pub_stage_identity_test.py',
            '$RUNNER_TEMP/archway-pub-stage/pub source café', '$GITHUB_WORKSPACE',
            'combined', 'transports', '$GITHUB_SHA', '${registry_args[@]+${registry_args[@]}}', '2>&1', '|', 'tee',
            'build/pub-producer/identity-controls.log'])
        self.assertEqual(commands[8][:4], ['python', '-u', 'tool/ci/pub_stage_transport.py', 'write'])
        self.assertIn('$RUNNER_TEMP/archway-pub-stage', commands[8])
        self.assertEqual(raw.count('test/pub_stage_identity_test.py'), 1)
        retained = next(s for s in audit['steps']
                        if s.get('name') == 'Retain bounded pub producer evidence even on failure')
        self.assertEqual(retained['if'], 'always()')
        paths = retained['with']['path'].splitlines()
        self.assertTrue(any(Path(commands[7][-1]).match(path) for path in paths))

    def test_failed_identity_serialization_cannot_publish_successful_job_output(self):
        workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        producer = next(s for s in workflow['jobs']['audit']['steps'] if s.get('id') == 'pub-transport')
        # Exercise the actual shell output boundary, after the preceding checked Git diff.
        script = 'set -euo pipefail\n' + producer['run'].split('git diff HEAD --exit-code\n', 1)[1]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            identity = root / 'build/pub-producer/identity.json'
            identity.parent.mkdir(parents=True)
            identity.write_text('{invalid JSON')
            output = root / 'job-output'
            result = subprocess.run(['bash', '-c', script], cwd=root,
                env={**os.environ, 'GITHUB_OUTPUT': str(output)}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(output.exists(), 'Failed serialization published a job output')

    def test_three_real_hosts_consume_same_attempt_with_safe_expected_identity(self):
        raw = WORKFLOW.read_text()
        jobs = yaml.load(raw, Loader=yaml.BaseLoader)['jobs']
        job = jobs['pub-installed']
        self.assertEqual(job['needs'], ['audit'])
        self.assertEqual(job['runs-on'], '${{ matrix.os }}')
        self.assertEqual(job['strategy'], {'fail-fast': 'false', 'matrix': {'include': [
            {'os': 'ubuntu-24.04', 'target': 'linux-x64'},
            {'os': 'macos-15', 'target': 'macos-arm64'},
            {'os': 'windows-2025', 'target': 'windows-x64'}]}})
        steps = job['steps']
        node = next(s for s in steps if 'setup-node@' in s.get('uses', ''))
        self.assertEqual(node['with'], {'node-version': '24.21.0'})
        self.assertEqual(node['uses'], 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020')
        cleanup = next(s for s in steps if s.get('name') == 'Check disposable source cleanup on native host')
        self.assertEqual(cleanup['run'], 'python test/pub_snapshot_cleanup_test.py')
        self.assertIn('core.autocrlf false', steps[0]['run'])
        self.assertEqual(steps[1]['with'], {'persist-credentials': 'false', 'ref': '${{ github.sha }}'})
        download = next(s for s in steps if 'download-artifact@' in s.get('uses', ''))
        self.assertEqual(download['with'], {
            'name': 'private-pub-stage-${{ github.run_id }}-${{ github.run_attempt }}', 'path': 'pub-input'})
        probe = next(s for s in steps if s.get('name') == 'Genuine pub launcher before and after disposable source deletion')
        self.assertEqual(probe['env']['EXPECTED_PUB_TRANSPORT'], '${{ needs.audit.outputs.pub-transport }}')
        runs = '\n'.join(s.get('run', '') for s in steps)
        for required in ['--expected-transport-json "$EXPECTED_PUB_TRANSPORT"',
                         '--expected-source "$GITHUB_SHA"', '--run-id "$GITHUB_RUN_ID"',
                         '--run-attempt "$GITHUB_RUN_ATTEMPT"', '--output "$PUB_PROBE_OUTPUT"',
                         '--prepared-cache "$PUB_PREPARED_CACHE"', '--dart "$PUB_DART"',
                         '--transport-archive pub-input/pub-stage.tar.gz',
                         'git diff HEAD --exit-code', '--prepare-cache', 'setup_pub_dart.py']:
            self.assertIn(required, runs)
        commands = [shlex.split(line) for line in probe['run'].replace('\\\n', ' ').splitlines()]
        self.assertEqual(commands, [
            ['set', '-euo', 'pipefail'],
            ['source', 'tool/ci/registry_candidate_arguments.sh'],
            ['python', '-u', 'tool/ci/pub_snapshot_probe.py', '--dart', '$PUB_DART',
             '--node', '$(node -p process.execPath)', '--source', '$GITHUB_WORKSPACE', '--prepared-cache', '$PUB_PREPARED_CACHE',
             '--target', '${{ matrix.target }}', '--output', '$PUB_PROBE_OUTPUT',
             '--transport-archive', 'pub-input/pub-stage.tar.gz', '--expected-transport-json',
             '$EXPECTED_PUB_TRANSPORT', '--expected-source', '$GITHUB_SHA',
             '--run-id', '$GITHUB_RUN_ID', '--run-attempt', '$GITHUB_RUN_ATTEMPT',
             '${registry_args[@]+${registry_args[@]}}', '2>&1', '|', 'tee', 'build/pub-installed/probe.log'],
            ['git', 'diff', 'HEAD', '--exit-code']])
        self.assertNotIn('${{ needs.', runs)
        self.assertNotIn('pub get', runs)  # Only the checksum-verified setup helper prepares it.
        self.assertNotIn('publish', runs)
        self.assertNotIn('package_delivery.py', runs)
        self.assertEqual(runs.count('tool/ci/pub_snapshot_probe.py'), 1)
        self.assertEqual(steps[-1]['if'], 'always()')
        retained = steps[-1]['with']['path'].splitlines()
        self.assertIn('${{ runner.temp }}/archway-pub-setup/probe/report.json', retained)
        self.assertTrue(all(not p.endswith('/') and '**' not in p for p in retained))

    def test_pinned_prerequisites_and_bounded_failure_reports(self):
        raw = WORKFLOW.read_text()
        jobs = yaml.load(raw, Loader=yaml.BaseLoader)['jobs']
        for name in ['audit', 'pub-installed']:
            steps = jobs[name]['steps']
            python = next(s for s in steps if 'setup-python@' in s.get('uses', ''))
            self.assertEqual(python['uses'], 'actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065')
            self.assertEqual(python['with'], {'python-version': '3.13.7'})
            runs = '\n'.join(s.get('run', '') for s in steps)
            self.assertIn("python -m pip --isolated install --index-url https://pypi.org/simple 'PyYAML==6.0.3'", runs)
            evidence = next(s for s in steps if s.get('name', '').startswith('Retain bounded'))
            self.assertEqual(evidence['if'], 'always()')
            self.assertEqual(evidence['with']['retention-days'], '1')
            paths = evidence['with']['path'].splitlines()
            self.assertTrue(any('setup.log' in p or '*.log' in p for p in paths))
            for path in paths:
                self.assertNotIn('cache', path)
                self.assertNotIn('dart-sdk', path)
                self.assertNotIn('received-stage', path)
                self.assertNotIn('pub source', path)
                self.assertTrue(path.endswith(('.log', '.json')))
        self.assertNotIn('continue-on-error', raw)
        self.assertNotIn('secrets:', raw)
        self.assertEqual(raw.count('npm pack --ignore-scripts --offline --json'), 1)


if __name__ == '__main__':
    unittest.main()
