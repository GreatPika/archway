"""Bounded fixture controls; these do not establish installed native acceptance."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
import npm_local_analysis as analysis


class AnalysisControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve() / 'project café'
        self.installed = self.root / 'node_modules/archway-architecture-cli'
        self.helper = self.installed / 'assets/typescript/helper.cjs'
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b'owned helper')
        self.foreign = Path(temporary.name).resolve() / 'foreign ü'
        self.foreign.mkdir()
        self.shim = self.root / 'node_modules/.bin/archway'
        # Literal contract outcomes; never derived from requested expected_exit.
        self.values = [
            (0, 'ok', {'policy_valid': True, 'analysis_complete': True, 'violations': [],
                       'tool_errors': [], 'unknowns': [], 'observed': {'files': 2, 'analyzed_files': 2, 'edges': 0}}),
            (1, 'negative', {'policy_valid': True, 'analysis_complete': True,
                            'violations': [{'code': 'DEPENDENCY_NOT_ALLOWED'}],
                            'tool_errors': [], 'unknowns': [], 'observed': {'files': 2, 'analyzed_files': 2, 'edges': 1}}),
            (64, 'usage_error', None),
            (2, 'incomplete', {'policy_valid': True, 'analysis_complete': False,
                               'tool_errors': [{'code': 'TYPESCRIPT_ASSETS_UNAVAILABLE'}]}),
            (0, 'ok', {'policy_valid': True, 'analysis_complete': True, 'violations': [],
                       'tool_errors': [], 'unknowns': [], 'observed': {'files': 2, 'analyzed_files': 2, 'edges': 0}}),
        ]
        self.effect = lambda code: None
        self.arguments = []

    def run_process_fixture(self, arguments, cwd, environment, expected_exit=0):
        code, status, payload = self.values.pop(0)
        self.arguments.append(arguments)
        self.assertEqual(arguments[:4], [str(self.shim), '--root', str(self.root), 'check'])
        self.assertEqual(cwd, self.foreign)
        if code == 2:
            self.assertFalse(self.helper.exists())
        self.effect(code)
        value = {'command': 'check', 'schema_version': 1, 'exit_code': code,
                 'status': status, 'payload': payload, 'tool_versions': {'typescript': '5.9.3'}}
        return subprocess.CompletedProcess(arguments, code, (json.dumps(value) + '\n').encode(), b'')

    def exercise(self):
        return analysis.exercise(self.shim, self.root, self.foreign, self.installed, {}, self.run_process_fixture)

    def test_read_only_installation_never_runs_asset_mutation_controls(self):
        before = analysis.snapshot(self.installed)
        cases = analysis.exercise(self.shim, self.root, self.foreign, self.installed,
                                  {}, self.run_process_fixture, read_only=True)
        self.assertEqual([case['exit'] for case in cases], [0, 1, 64])
        self.assertEqual(analysis.snapshot(self.installed), before)
        self.assertEqual(len(self.values), 2)

    def test_exercises_five_cases_and_restores_owned_helper(self):
        cases = self.exercise()
        self.assertEqual([case['exit'] for case in cases], [0, 1, 64, 2, 0])
        self.assertEqual(self.arguments[2][-1], '--unsupported')
        self.assertEqual(self.helper.read_bytes(), b'owned helper')
        self.assertEqual(self.values, [])

    def test_global_package_is_bound_to_separate_prefix_and_cannot_write_it(self):
        prefix = self.root.parent / 'global prefix ü'
        package = prefix / 'lib/node_modules/archway-architecture-cli'
        package.parent.mkdir(parents=True)
        self.installed.rename(package)
        self.installed = package
        self.helper = package / 'assets/typescript/helper.cjs'
        self.shim = prefix / 'bin/archway'
        self.assertFalse((self.root / 'node_modules/archway-architecture-cli').exists())
        self.effect = lambda code: (package / 'unexpected').write_text('changed')
        with self.assertRaisesRegex(AssertionError, 'unexpectedly changed installation'):
            analysis.exercise(self.shim, self.root, self.foreign, package, {}, self.run_process_fixture,
                              installation_root=prefix)

    def test_global_package_cannot_escape_expected_prefix_via_alias(self):
        prefix = self.root.parent / 'global prefix ü'
        prefix.mkdir()
        alias = prefix / 'aliased package'
        try:
            alias.symlink_to(self.installed, target_is_directory=True)
        except OSError as error:
            self.skipTest(str(error))
        with self.assertRaises(AssertionError):
            analysis.exercise(self.shim, self.root, self.foreign, alias, {}, self.run_process_fixture,
                              installation_root=prefix)

    def test_package_alias_outside_prefix_is_not_a_global_installation(self):
        prefix = self.root.parent / 'global prefix ü'
        package = prefix / 'node_modules/archway-architecture-cli'
        package.parent.mkdir(parents=True)
        self.installed.rename(package)
        self.helper = package / 'assets/typescript/helper.cjs'
        alias = self.root / 'outside prefix alias'
        try:
            alias.symlink_to(package, target_is_directory=True)
        except OSError as error:
            self.skipTest(str(error))
        with self.assertRaises(AssertionError):
            analysis.exercise(self.shim, self.root, self.foreign, alias, {}, self.run_process_fixture,
                              installation_root=prefix)

    def test_default_local_containment_is_not_relaxed(self):
        with self.assertRaises(AssertionError):
            analysis.exercise(self.shim, self.foreign, self.root, self.installed, {}, self.run_process_fixture)

    def test_rejects_fake_success_when_analysis_is_incomplete(self):
        self.values[0][2]['analysis_complete'] = False
        with self.assertRaisesRegex(AssertionError, 'Wrong analysis completeness'):
            self.exercise()

    def test_rejects_decoy_execution(self):
        self.effect = lambda code: (self.root / 'project-decoy-executed').write_text('executed')
        with self.assertRaisesRegex(AssertionError, 'Project decoy executed'):
            self.exercise()

    def test_rejects_unrequested_project_write(self):
        self.effect = lambda code: (self.root / 'unexpected').write_text('changed')
        with self.assertRaisesRegex(AssertionError, 'unexpectedly changed project'):
            self.exercise()

    def test_rejects_unrequested_foreign_write(self):
        self.effect = lambda code: (self.foreign / 'unexpected').write_text('changed')
        with self.assertRaisesRegex(AssertionError, 'unexpectedly changed foreign'):
            self.exercise()

    def test_restores_helper_when_incomplete_process_raises(self):
        def failure(code):
            if code == 2:
                raise RuntimeError('Process failure')
        self.effect = failure
        with self.assertRaisesRegex(RuntimeError, 'Process failure'):
            self.exercise()
        self.assertEqual(self.helper.read_bytes(), b'owned helper')
        self.assertFalse(self.helper.with_suffix('.cjs.saved').exists())

    def test_rejects_wrong_actual_exit_despite_success_json(self):
        result = subprocess.CompletedProcess([], 1, b'{"command":"check","schema_version":1,"status":"ok","exit_code":0}\n', b'')
        with self.assertRaisesRegex(AssertionError, 'Actual exit'):
            analysis.assert_result(result, 0, 'ok')

    def test_rejects_wrong_envelope_status_and_exit(self):
        for key, value in [('status', 'negative'), ('exit_code', 1)]:
            record = {'command': 'check', 'schema_version': 1, 'status': 'ok', 'exit_code': 0}
            record[key] = value
            result = subprocess.CompletedProcess([], 0, (json.dumps(record) + '\n').encode(), b'')
            with self.subTest(key=key), self.assertRaises(AssertionError):
                analysis.assert_result(result, 0, 'ok')

    def test_rejects_bad_json_framing_or_stderr(self):
        raw = b'{"command":"check","schema_version":1,"status":"ok","exit_code":0}\n'
        for stdout, stderr in [(raw + b'\n', b''), (raw[:-1], b''),
                               (b'\xef\xbb\xbf' + raw, b''), (raw, b'noise')]:
            with self.subTest(stdout=stdout, stderr=stderr), self.assertRaises(AssertionError):
                analysis.assert_result(subprocess.CompletedProcess([], 0, stdout, stderr), 0, 'ok')


if __name__ == '__main__':
    unittest.main()
