"""Static workflow contract checks (requires PyYAML); not native CI acceptance."""
from pathlib import Path
import unittest
import os
import subprocess
import sys
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def check_workflow(self, filename, target):
        workflow = yaml.load((ROOT / '.github/workflows' / filename).read_text(),
                             Loader=yaml.BaseLoader)
        self.assertEqual(set(workflow['on']), {'workflow_call', 'workflow_dispatch'})
        for event in ('workflow_call', 'workflow_dispatch'):
            option = workflow['on'][event]['inputs']['export-installation']
            self.assertEqual(option['type'], 'boolean')
            self.assertEqual(option['default'], 'false')
            self.assertEqual(option['required'], 'false')
        self.assertIn("inputs.export-installation && 'export' || 'probe'",
                      workflow['concurrency']['group'])
        steps = next(iter(workflow['jobs'].values()))['steps']
        uploads = [s for s in steps if 'upload-artifact@' in s.get('uses', '')]
        artifact, evidence = uploads
        self.assertEqual(artifact['uses'], 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02')
        self.assertEqual(artifact['if'], '${{ success() && inputs.export-installation }}')
        settings = artifact['with']
        destination = '${{ runner.temp }}/archway-native-export-' + target
        self.assertEqual(settings['path'].splitlines(),
                         [destination + '/installation.tar', destination + '/provenance.json'])
        self.assertEqual(settings['retention-days'], '1')
        self.assertEqual(settings['compression-level'], '0')
        self.assertEqual(settings['if-no-files-found'], 'error')
        self.assertNotIn('overwrite', settings)
        self.assertIn(target + '-${{ github.run_id }}-${{ github.run_attempt }}', settings['name'])
        self.assertEqual(evidence['if'], 'always()')
        self.assertNotIn('archway-native-export', evidence['with']['path'])
        checkout = next(i for i, step in enumerate(steps) if 'checkout@' in step.get('uses', ''))
        preparation, verification = steps[checkout - 1], steps[checkout + 1]
        for step in (preparation, verification):
            self.assertEqual(step['if'], '${{ inputs.export-installation }}')
        self.assertIn('git config --global core.autocrlf false', preparation['run'])
        self.assertIn('verify_export_sources.py', verification['run'])
        self.assertIn('GITHUB_SHA', verification['run'])
        assembly = steps[steps.index(artifact) - 1]
        self.assertNotIn('if', assembly)  # Ordinary failure gating remains in force.
        self.assertNotIn('continue-on-error', assembly)
        self.assertIn('archway-native-export-' + target, assembly['run'])
        runs = '\n'.join(step.get('run', '') for step in steps)
        self.assertNotIn('macos_aot_init_probe.py', runs)
        self.assertNotIn('-Phase aot-init', runs)
        self.assertNotIn('continue-on-error', str(workflow))
        if target == 'macos-arm64':
            self.assertEqual(runs.count('native_assembly_init_probe.dart'), 1)
        else:
            self.assertIn("$arguments = @{ Phase = 'assembly-init' }", assembly['run'])

    def test_macos_export_is_opt_in_and_success_only(self):
        self.check_workflow('macos-native-probe.yml', 'macos-arm64')

    def test_windows_export_is_opt_in_and_success_only(self):
        self.check_workflow('windows-native-probe.yml', 'windows-x64')


    def test_macos_command_forwards_optional_path_and_preserves_failure(self):
        workflow = yaml.load((ROOT / '.github/workflows/macos-native-probe.yml').read_text(), Loader=yaml.BaseLoader)
        command = next(s['run'] for s in workflow['jobs']['macos-init']['steps']
                       if 'native_assembly_init_probe.dart' in s.get('run', ''))
        with tempfile.TemporaryDirectory(prefix='export path ') as directory:
            (Path(directory) / 'build/macos-probe').mkdir(parents=True)
            for enabled, exit_code in (('', '0'), ('false', '0'), ('true', '0'), ('true', '7')):
                env = dict(os.environ, EXPORT_INSTALLATION=enabled, RUNNER_TEMP=directory, PROBE_EXIT=exit_code)
                stub = 'dart() { printf "%s\\n" "$@"; return "$PROBE_EXIT"; };\n'
                result = subprocess.run(['bash', '-eo', 'pipefail', '-c', stub + command],
                                        cwd=directory, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, int(exit_code), result.stderr)
                args = result.stdout.splitlines()
                self.assertEqual('--artifact-directory' in args, enabled == 'true')
                if enabled == 'true':
                    self.assertEqual(args[args.index('--artifact-directory') + 1],
                                     directory + '/archway-native-export-macos-arm64')

    def test_windows_wrapper_restricts_export_to_final_assembly(self):
        wrapper = (ROOT / 'tool/ci/windows-native-probe.ps1').read_text()
        self.assertIn("if ($ArtifactDirectory -and $Phase -ne 'assembly-init')", wrapper)
        self.assertIn("$arguments += @('--artifact-directory', $ArtifactDirectory)", wrapper)
        self.assertIn('& $dart @arguments', wrapper)
        self.assertNotIn("'aot-init'", wrapper)
        self.assertNotIn('aot-init-passed.txt', wrapper)
        self.assertIn('if (!(Test-Path "$evidence/aot-assets-passed.txt"))', wrapper)
        self.assertIn("$arguments = @('--suppress-analytics', 'run', 'tool/ci/native_assembly_init_probe.dart', '--init-only', '--dart', $dart)", wrapper)
        self.assertIn("if ($LASTEXITCODE -ne 0) { throw 'Maintainer assembly/init assertion failed;", wrapper)
        self.assertLess(wrapper.index("throw 'ArtifactDirectory"), wrapper.index('Start-Transcript'))


class SourceBytesTests(unittest.TestCase):
    def test_export_verifier_accepts_exact_git_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args])
            git('init', '-q')
            git('config', 'core.autocrlf', 'true')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            for name in ('pubspec.lock', 'assets/typescript/helper.cjs',
                         'assets/typescript/package-lock.json'):
                file = repo / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b'exact\nbytes\n')
            git('add', '.')
            git('commit', '-qm', 'Fixture')
            sha = git('rev-parse', 'HEAD').decode().strip()
            command = [sys.executable, str(ROOT / 'tool/ci/verify_export_sources.py'), sha]
            result = subprocess.run(command, cwd=repo, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            (repo / 'assets/typescript/helper.cjs').unlink()
            git('checkout', '--', 'assets/typescript/helper.cjs')
            self.assertEqual((repo / 'assets/typescript/helper.cjs').read_bytes(), b'exact\r\nbytes\r\n')
            self.assertEqual(git('status', '--porcelain'), b'')
            result = subprocess.run(command, cwd=repo, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Export source bytes differ from Git', result.stderr)
            result = subprocess.run(command[:-1] + ['0' * 40], cwd=repo, capture_output=True)
            self.assertIn(b'Checkout commit differs', result.stderr)


if __name__ == '__main__':
    unittest.main()
