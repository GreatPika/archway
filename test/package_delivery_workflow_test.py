"""Static delivery wiring checks; genuine three-host CI remains required."""
from pathlib import Path
import shlex
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class DeliveryWorkflowTests(unittest.TestCase):
    def test_same_source_success_gated_run(self):
        path = ROOT / '.github/workflows/package-delivery-probe.yml'
        raw = path.read_text()
        workflow = yaml.load(raw, Loader=yaml.BaseLoader)
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        push = workflow['on']['push']
        self.assertEqual(workflow['name'], 'Release acceptance and portable artifacts')
        self.assertEqual(push['branches'], ['main', 'integration/archway-v1', 'release/**'])
        self.assertEqual(set(push['paths']), {
            '.github/workflows/**', 'tool/**', 'test/**', 'lib/**', 'bin/**',
            'assets/**', 'native/**', 'contracts/**', 'pubspec.yaml',
            'pubspec.lock', 'analysis_options.yaml', 'README.md', 'LICENSE'})
        self.assertIn('workflow_dispatch', workflow['on'])
        self.assertNotIn('Bootstrap on integration', raw)
        jobs = workflow['jobs']
        for target, file in [('macos', 'macos-native-probe.yml'), ('windows', 'windows-native-probe.yml')]:
            self.assertEqual(jobs[target], {'uses': './.github/workflows/' + file,
                                           'with': {'export-installation': 'true'}})
        self.assertEqual(set(jobs['audit']['needs']), {'linux', 'macos', 'windows'})
        downloads = [s for s in jobs['audit']['steps'] if 'download-artifact@' in s.get('uses', '')]
        self.assertEqual(len(downloads), 3)
        for step, target in zip(downloads, ['linux-x64', 'macos-arm64', 'windows-x64']):
            self.assertEqual(step['uses'], 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093')
            self.assertEqual(step['with'], dict(name='native-installation-' + target +
                             '-${{ github.run_id }}-${{ github.run_attempt }}', path='transports/' + target))
        self.assertNotIn('continue-on-error', raw)
        cleanup = next(s for s in jobs['npm-installed']['steps'] if 'windows-cleanup.log' in s.get('run', ''))
        self.assertEqual(cleanup['if'], "matrix.target == 'windows-x64'")
        self.assertIn('test/npm_windows_job_test.py --require-windows', cleanup['run'])
        self.assertIn('set -euo pipefail', cleanup['run'])
        self.assertNotIn('secrets:', raw)
        self.assertEqual(raw.count('npm pack --ignore-scripts --offline --json'), 1)
        runs = '\n'.join(s.get('run', '') for s in jobs['audit']['steps'])
        self.assertLess(runs.index('audit_installation_transports.dart'), runs.index('combine_installations.py combine'))
        self.assertLess(runs.index('combine_installations.py combine'), runs.index('tool/package_delivery.py npm'))
        self.assertLess(runs.index('tool/package_delivery.py npm'), runs.index('npm pack'))
        self.assertLess(runs.index('npm pack'), runs.index('combine_installations.py verify-pack'))
        self.assertIn('sha256sum -c -', runs)
        self.assertIn('npm --version', runs)
        upload = jobs['audit']['steps'][-1]
        self.assertEqual(upload['if'], 'success()')
        self.assertEqual(upload['with']['retention-days'], '1')
        self.assertEqual(upload['with']['if-no-files-found'], 'error')
        self.assertIn('packed/*.tgz', upload['with']['path'])
        self.assertIn('packed/packed-evidence.json', upload['with']['path'])
        self.assertNotIn('npm install', runs)
        self.assertNotIn('npm publish', raw)
        self.assertIn('--expected-commit "$GITHUB_SHA"', raw)

    def test_pack_boundary_pins_current_source_runtime_and_single_output(self):
        workflow = yaml.load((ROOT / '.github/workflows/package-delivery-probe.yml').read_text(),
                             Loader=yaml.BaseLoader)
        steps = workflow['jobs']['audit']['steps']
        self.assertIn('core.autocrlf false', steps[0]['run'])
        checkout = steps[1]
        self.assertEqual(checkout['uses'], 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683')
        self.assertEqual(checkout['with'], {'persist-credentials': 'false', 'ref': '${{ github.sha }}'})
        pack = next(s for s in steps if s.get('name') ==
                    'Combine verified installations and pack once without install scripts')
        self.assertEqual(pack['shell'], 'bash')
        lines = [line.strip() for line in pack['run'].replace('\\\n', ' ').splitlines()]
        self.assertIn('test "$(node --version)" = v24.21.0', lines)
        self.assertIn('test "$(npm --version)" = 11.19.0', lines)
        combine = next(shlex.split(line) for line in lines if 'combine_installations.py combine' in line)
        self.assertEqual(combine, ['python3', 'tool/ci/combine_installations.py', 'combine',
                                  '--expected-commit', '$GITHUB_SHA', '--output', 'combined',
                                  'transports/linux-x64', 'transports/macos-arm64', 'transports/windows-x64'])
        all_runs = '\n'.join(s.get('run', '') for job in workflow['jobs'].values()
                             for s in job.get('steps', []))
        tokens = shlex.split(all_runs)
        self.assertEqual(sum(pair == ('npm', 'pack') for pair in zip(tokens, tokens[1:])), 1)
        self.assertIn('(cd package && npm pack --ignore-scripts --offline --json '
                      '--pack-destination ../packed) > packed/npm-pack.json', lines)
        upload = steps[-1]
        self.assertEqual(upload['uses'], 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')
        self.assertEqual(upload['with']['name'], 'private-npm-pack-${{ github.run_id }}-${{ github.run_attempt }}')
        self.assertEqual(upload['with']['compression-level'], '0')
        self.assertNotIn('overwrite', upload['with'])
        self.assertEqual(set(upload['with']['path'].splitlines()), {
            'packed/*.tgz', 'packed/packed-evidence.json', 'packed/npm-pack.json',
            'packed/*-version.txt', 'combined/transport-audit.json', 'combined/provenance/*.json'})

    def test_three_npm_routes_use_one_same_attempt_tarball(self):
        workflow = yaml.load((ROOT / '.github/workflows/package-delivery-probe.yml').read_text(),
                             Loader=yaml.BaseLoader)
        job = workflow['jobs']['npm-installed']
        self.assertEqual(set(job), {'needs', 'runs-on', 'timeout-minutes', 'strategy', 'steps'})
        self.assertEqual(job['needs'], ['audit'])
        self.assertEqual(job['strategy']['fail-fast'], 'false')
        self.assertEqual(set(job['strategy']['matrix']), {'os', 'route', 'include'})
        self.assertEqual(job['strategy']['matrix']['os'], ['ubuntu-24.04', 'macos-15', 'windows-2025'])
        self.assertEqual(job['strategy']['matrix']['route'], ['local', 'global', 'cache'])
        self.assertEqual(job['strategy']['matrix']['include'], [
            {'os': 'ubuntu-24.04', 'target': 'linux-x64'},
            {'os': 'macos-15', 'target': 'macos-arm64'},
            {'os': 'windows-2025', 'target': 'windows-x64'}])
        self.assertEqual(job['runs-on'], '${{ matrix.os }}')
        self.assertEqual(job['timeout-minutes'],
            "${{ matrix.os == 'windows-2025' && matrix.route == 'cache' && 20 || 10 }}")
        steps = job['steps']
        self.assertEqual(steps[0]['with'], {'persist-credentials': 'false', 'ref': '${{ github.sha }}'})
        self.assertEqual(steps[0]['uses'], 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683')
        self.assertEqual(steps[1], {'uses': 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020',
                                  'with': {'node-version': '24.21.0'}})
        self.assertEqual(steps[2], {'uses': 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093',
                                  'with': {'name': 'private-npm-pack-${{ github.run_id }}-${{ github.run_attempt }}',
                                           'path': 'npm-input'}})
        setup = steps[3]
        self.assertEqual(setup['shell'], 'bash')
        self.assertIn('tool/ci/setup_npm_wrong_node.py', setup['run'])
        self.assertIn("--target '${{ matrix.target }}'", setup['run'])
        self.assertIn('runtime.json', setup['run'])
        probe = steps[5]
        self.assertEqual(probe['shell'], 'bash')
        self.assertEqual(probe['env'], {'PYTHONUTF8': '1'})
        # Exact ordered commands protect the no-build/no-repack boundary and
        # prevent shell suffixes from swallowing the real probe's failure.
        commands = [shlex.split(line) for line in probe['run'].replace('\\\n', ' ').splitlines()]
        self.assertEqual(commands, [
            ['set', '-euo', 'pipefail'],
            ['source', 'tool/ci/registry_candidate_arguments.sh'],
            ['mkdir', '-p', 'build/npm-local'],
            ['python', '-u', 'tool/ci/npm_local_install_probe.py',
             '--packed-directory', 'npm-input/packed', '--target', '${{ matrix.target }}',
             '--route', '${{ matrix.route }}', '--wrong-node', '$ARCHWAY_WRONG_NODE',
             '--runner-label', '${{ matrix.os }}', '--report', 'build/npm-local/report.json',
             '${registry_args[@]+${registry_args[@]}}', '2>&1', '|', 'tee', 'build/npm-local/probe.log']])
        self.assertEqual(steps[6]['if'], 'always()')
        self.assertEqual(steps[6]['uses'], 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')
        self.assertEqual(steps[6]['with'], {
            'name': 'npm-installed-${{ matrix.route }}-${{ matrix.target }}-${{ github.run_id }}-${{ github.run_attempt }}',
            'path': 'build/npm-local/', 'retention-days': '1', 'if-no-files-found': 'warn'})
        self.assertEqual(len(steps), 7)

    def test_linux_discovers_python_controls_with_existing_pinned_runtimes(self):
        workflow = yaml.load((ROOT / '.github/workflows/package-delivery-probe.yml').read_text(),
                             Loader=yaml.BaseLoader)
        steps = workflow['jobs']['linux']['steps']
        setup = next(s for s in steps if s.get('name') ==
                     'Install official checksum-verified Linux toolchains')
        regression = next(s for s in steps if s.get('name') ==
                          'Python regression suite with pinned runtime fixtures')
        assembly = next(s for s in steps if 'native_assembly_init_probe.dart' in s.get('run', ''))
        self.assertLess(steps.index(setup), steps.index(regression))
        self.assertLess(steps.index(regression), steps.index(assembly))
        self.assertIn("'jsonschema==4.26.0' 'PyYAML==6.0.3'", setup['run'])
        self.assertEqual(regression['env'], {
            'ARCHWAY_TEST_DART_SDK': '${{ runner.temp }}/archway-dart/dart-sdk',
            'ARCHWAY_TEST_NODE': '${{ runner.temp }}/archway-node/node-v24.21.0-linux-x64/bin/node'})
        commands = [shlex.split(line) for line in regression['run'].splitlines()]
        self.assertEqual(commands, [
            ['set', '-euo', 'pipefail'],
            ['python3', '-m', 'unittest', 'discover', '-s', 'test', '-p', '*_test.py',
             '2>&1', '|', 'tee', 'build/delivery-probe/python-regression.log']])
        self.assertNotIn('if', regression)
        self.assertNotIn('continue-on-error', regression)

    def test_linux_reuses_owned_build_and_export_pipeline(self):
        workflow = yaml.load((ROOT / '.github/workflows/package-delivery-probe.yml').read_text(),
                             Loader=yaml.BaseLoader)
        linux = workflow['jobs']['linux']
        self.assertEqual(linux['runs-on'], 'ubuntu-24.04')
        steps = linux['steps']
        self.assertIn('core.autocrlf false', steps[0]['run'])
        self.assertEqual(steps[1]['with']['ref'], '${{ github.sha }}')
        runs = '\n'.join(step.get('run', '') for step in steps)
        self.assertLess(runs.index('unzip'), runs.index('verify_export_sources.dart'))
        self.assertLess(runs.index('verify_export_sources.dart'), runs.index('pub get --enforce-lockfile'))
        self.assertIn('tool/ci/verify_export_sources.dart "$GITHUB_SHA"', runs)
        for required in ['pub get --enforce-lockfile', 'bash tool/prepare_typescript.sh',
                         'native_assembly_init_probe.dart', '--dart-sdk', '--node',
                         '--artifact-directory', 'sha256sum -c -']:
            self.assertIn(required, runs)
        payload, evidence = [s for s in steps if 'upload-artifact@' in s.get('uses', '')]
        self.assertEqual(payload['if'], 'success()')
        self.assertEqual(evidence['if'], 'always()')
        self.assertEqual(payload['with']['if-no-files-found'], 'error')
        self.assertEqual(payload['with']['compression-level'], '0')
        self.assertEqual(payload['with']['retention-days'], '1')
        self.assertEqual(len(payload['with']['path'].splitlines()), 2)
        self.assertNotIn('overwrite', payload['with'])
        for job in workflow['jobs'].values():
            self.assertNotIn('if', job)
            for step in job.get('steps', []):
                if 'checkout@' in step.get('uses', ''):
                    self.assertEqual(step['with']['persist-credentials'], 'false')
                if 'run' in step:
                    if 'windows-cleanup.log' in step['run']:
                        self.assertEqual(step.get('if'), "matrix.target == 'windows-x64'")
                    else:
                        self.assertNotIn('if', step)


if __name__ == '__main__':
    unittest.main()
