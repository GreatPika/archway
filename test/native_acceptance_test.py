"""Acceptance runner contract: complete suite inventory and real child results."""
import json
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool/ci'))
from native_acceptance import suite_commands, execute_suite, read_fixtures, run_acceptance


class NativeAcceptance(unittest.TestCase):
    def test_independent_failures_collect_later_results_with_or_without_source_error(self):
        for source_error in (None, ValueError('source gate failed')):
            with self.subTest(source_error=source_error), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / 'acceptance'
                fixtures = {'dart_sdk': Path(temp), 'environment': {}}
                commands = [(name, [sys.executable, '-c', f'print("{name}"); exit({code})'])
                            for name, code in [('early', 7), ('middle', 0), ('late', 9)]]
                with patch('native_acceptance.source_identity', return_value={'commit': 'fixed'}), \
                        patch('native_acceptance.read_fixtures', return_value=(fixtures, {})), \
                        patch('native_acceptance.suite_commands', return_value=commands), \
                        patch('native_acceptance.run_source_tests', side_effect=source_error, return_value={'passed': True}) as source, \
                        patch('native_acceptance.print'), \
                        patch('native_acceptance.os.environ', {}):
                    with self.assertRaisesRegex(ValueError, 'early.*late' + ('.*source gate failed' if source_error else '')):
                        run_acceptance(ROOT, Path('/binary'), Path('/node'), Path('/fixtures'),
                                       output, lambda: None)
                source.assert_called_once()
                for name, code in [('early', 7), ('middle', 0), ('late', 9)]:
                    self.assertEqual(json.loads((output / (name + '.json')).read_text())['exit_code'], code)
                failures = json.loads((output / 'failures.json').read_text())
                self.assertEqual([entry['suite'] for entry in failures], ['early', 'late'] + (['source'] if source_error else []))

    def test_timeout_and_archive_drift_stop_before_later_suites(self):
        for failure in ('timeout', 'archive drift'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / 'acceptance'
                command = [sys.executable, '-c', 'import time; time.sleep(5)']
                if failure == 'archive drift':
                    command = [sys.executable, '-c', 'exit(7)']
                with patch('native_acceptance.source_identity', return_value={}), \
                        patch('native_acceptance.read_fixtures', return_value=(
                            {'dart_sdk': Path(temp), 'environment': {}}, {})), \
                        patch('native_acceptance.suite_commands', return_value=[
                            ('early', command), ('later', [sys.executable, '-c', 'exit(0)'])]), \
                        patch('native_acceptance.run_source_tests') as source, \
                        patch('native_acceptance.SUITE_TIMEOUT', 0.2), \
                        patch('native_acceptance.print'):
                    verify = Mock(side_effect=[None, ValueError('archive drift')]
                                  if failure == 'archive drift' else None)
                    with self.assertRaisesRegex(ValueError, 'timed out|archive drift'):
                        run_acceptance(ROOT, Path('/binary'), Path('/node'), Path('/fixtures'), output, verify)
                source.assert_not_called()
                self.assertEqual(verify.call_count, 2)
                self.assertTrue((output / 'early.json').is_file())
                self.assertFalse((output / 'later.json').exists())

    def test_success_returns_all_receipts_without_failure_report(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'acceptance'
            with patch('native_acceptance.source_identity', return_value={'commit': 'fixed'}), \
                    patch('native_acceptance.read_fixtures', return_value=(
                        {'dart_sdk': Path(temp), 'environment': {}}, {})), \
                    patch('native_acceptance.suite_commands', return_value=[
                        ('example', [sys.executable, '-c', 'exit(0)'])]), \
                    patch('native_acceptance.run_source_tests', return_value={'passed': True}), \
                    patch('native_acceptance.print'):
                result = run_acceptance(ROOT, Path('/binary'), Path('/node'), Path('/fixtures'), output, lambda: None)
            self.assertEqual([entry['suite'] for entry in result['suites']], ['example'])
            self.assertEqual(result['source_suite'], {'passed': True})
            self.assertFalse((output / 'failures.json').exists())

    def test_full_linux_inventory_uses_supplied_archive_binary(self):
        binary = Path('/extracted/bin/linux-x64/archway')
        fixtures = {key: Path('/fixtures') / key for key in (
            'dart_sdk', 'wrong_node', 'pub_fixture', 'git_fixture',
            'flutter_sdk', 'flutter_fixture')}
        commands = suite_commands(ROOT, binary, Path('/node'), fixtures, Path('/logs'))
        self.assertEqual(dict(commands)['runtime_request'][-1], str(Path('/logs/runtime-request-coverage.json')))
        expected = {'plan_query', 'cli', 'catalogue_export', 'check', 'dart_check',
                    'physical_path', 'alias_wire', 'alias_hop_recheck', 'alias_trace_gap',
                    'dart_resource', 'runtime', 'runtime_request', 'runtime_preflight',
                    'native_asset', 'native_abi', 'native_fault', 'package_provenance',
                    'dart_flutter'}
        self.assertEqual({name for name, command in commands}, expected)
        for name, command in commands:
            self.assertEqual(command[0], sys.executable)
            self.assertEqual(command[2], str(binary), name)
        self.assertIn('--existing-installation', dict(commands)['dart_check'])

    def test_fixture_manifest_preserves_prepared_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            node = base / 'node'
            node.write_text('version fixture')
            manifest = {key: str(base) for key in (
                'dart_sdk', 'pub_fixture', 'git_fixture', 'flutter_sdk', 'flutter_fixture')}
            manifest['wrong_node'] = str(node)
            manifest['environment'] = {'PUB_CACHE': str(base / 'isolated cache')}
            path = base / 'fixtures.json'
            path.write_text(json.dumps(manifest))
            fixtures, provenance = read_fixtures(path)
            self.assertEqual(fixtures['environment'], manifest['environment'])
            self.assertEqual(provenance['manifest'], manifest)
            manifest['environment']['PUB_CACHE'] = 123
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'environment'):
                read_fixtures(path)

    def test_child_failure_keeps_stdout_stderr_and_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            command = [sys.executable, '-c',
                       'import sys; print("partial evidence"); print("fault", file=sys.stderr); sys.exit(7)']
            with self.assertRaisesRegex(ValueError, 'example.*7'):
                execute_suite('example', command, ROOT, dict(os.environ), output)
            self.assertEqual((output / 'example.stdout.log').read_text(), 'partial evidence\n')
            self.assertEqual((output / 'example.stderr.log').read_text(), 'fault\n')

    def test_timeout_keeps_partial_output_and_failure_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            command = [sys.executable, '-c',
                       'import time; print("before timeout", flush=True); time.sleep(5)']
            with patch('native_acceptance.SUITE_TIMEOUT', 0.2):
                with self.assertRaisesRegex(ValueError, 'example.*timed out'):
                    execute_suite('example', command, ROOT, dict(os.environ), output)
            proof = json.loads((output / 'example.json').read_text())
            self.assertTrue(proof['timed_out'])
            self.assertIsNone(proof['exit_code'])
            self.assertEqual(proof['timeout_seconds'], 0.2)
            self.assertEqual((output / proof['stdout']).read_text(), 'before timeout\n')
            self.assertEqual(len(proof['stdout_sha256']), 64)

    def test_child_success_records_command_and_proof_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            command = [sys.executable, '-c', 'print("real subprocess passed")']
            proof = execute_suite('example', command, ROOT, dict(os.environ), output)
            self.assertEqual(proof['exit_code'], 0)
            self.assertEqual(proof['command'], command)
            self.assertGreater(proof['timeout_seconds'], 120)
            self.assertEqual(len(proof['stdout_sha256']), 64)
            self.assertEqual(proof['stderr_sha256'],
                             'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')


if __name__ == '__main__':
    unittest.main()
