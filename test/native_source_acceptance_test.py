"""Source-suite machine-report acceptance rejects incomplete or skipped fixtures."""
import os
import subprocess
import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from native_source_acceptance import summarize_tests, source_test_environment


def events(path, *, skipped=False, name='example', success=True):
    return [
        {'type': 'suite', 'suite': {'id': 0, 'path': path}},
        {'type': 'testStart', 'test': {'id': 1, 'suiteID': 0, 'name': name,
                                     'metadata': {'skipReason': 'fixture missing' if skipped else None}}},
        {'type': 'testDone', 'testID': 1, 'result': 'success', 'skipped': skipped, 'hidden': False},
        {'type': 'done', 'success': success},
    ]


class NativeSourceAcceptance(unittest.TestCase):
    def test_source_temporaries_use_one_canonical_private_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            parent = Path(temp)
            child = parent / 'child'
            child.mkdir()
            environment = source_test_environment(dict(os.environ), child / '..')
            expected = str((parent / 'test-tmp').resolve())
            for key in ('TMPDIR', 'TMP', 'TEMP', 'RUNNER_TEMP'):
                self.assertEqual(environment[key], expected)
            actual = subprocess.check_output([sys.executable, '-c',
                'import tempfile; print(tempfile.gettempdir())'], env=environment, text=True).strip()
            self.assertEqual(actual, expected)

    def test_python_fixture_binding_survives_a_sanitized_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            supplied = {**os.environ, 'PATH': '', 'ARCHWAY_TEST_PYTHON': 'untrusted-name'}
            environment = source_test_environment(supplied, Path(temporary))
            self.assertEqual(environment['PATH'], '')
            self.assertEqual(environment['ARCHWAY_TEST_PYTHON'], str(Path(sys.executable).resolve(strict=True)))
            self.assertEqual(supplied['ARCHWAY_TEST_PYTHON'], 'untrusted-name')
            subprocess.run([environment['ARCHWAY_TEST_PYTHON'], '-c', 'import tarfile'],
                           env=environment, check=True)

    def test_windows_fifo_inapplicability_requires_its_exact_reason(self):
        path = 'test/catalogue_export_test.dart'
        records = events(path, skipped=True,
            name='overwrite rejects a FIFO with a live reader before sending content')
        records[1]['test']['metadata']['skipReason'] = (
            'POSIX FIFO entries are unavailable on Windows; Win32 sharing faults have separate process coverage.')
        self.assertEqual(len(summarize_tests(records, {path}, 'windows-x64')['skipped']), 1)
        for target, reason in [('linux-x64', records[1]['test']['metadata']['skipReason']),
                               ('windows-x64', 'missing dependency')]:
            records[1]['test']['metadata']['skipReason'] = reason
            with self.assertRaisesRegex(ValueError, 'Unapproved source test skip'):
                summarize_tests(records, {path}, target)

    def test_complete_real_protocol_result_is_accepted(self):
        path = 'test/dart_flutter_test.dart'
        report = summarize_tests(events(path), {path}, 'linux-x64')
        self.assertEqual(report['passed'], 1)
        self.assertEqual(report['skipped'], [])
        self.assertEqual(report['suites'], [path])

    def hidden_loader_events(self, path):
        records = events(path)[:-1]
        records.extend([
            {'type': 'testStart', 'test': {'id': 2, 'suiteID': 0,
             'name': 'loading ' + path, 'groupIDs': [], 'url': None,
             'metadata': {'skip': False, 'skipReason': None}}},
            {'type': 'testDone', 'testID': 2, 'result': 'success',
             'hidden': True, 'skipped': False},
            {'type': 'done', 'success': True}])
        return records

    def test_real_hidden_load_and_hooks_do_not_replace_visible_tests(self):
        canonical = 'test/dart_flutter_test.dart'
        for target, path in [('linux-x64', canonical), ('macos-arm64', canonical),
                             ('windows-x64', canonical.replace('/', '\\'))]:
            with self.subTest(target=target):
                records = self.hidden_loader_events(path)[:-1]
                for number, name in enumerate(('(setUpAll)', '(tearDownAll)'), 3):
                    records.extend([
                        {'type': 'testStart', 'test': {'id': number, 'suiteID': 0,
                         'name': name, 'groupIDs': [], 'url': None,
                         'metadata': {'skip': False, 'skipReason': None}}},
                        {'type': 'testDone', 'testID': number, 'result': 'success',
                         'hidden': True, 'skipped': False}])
                records.append({'type': 'done', 'success': True})
                result = summarize_tests(records, {canonical}, target)
                self.assertEqual(result['passed'], 1)
                self.assertEqual(result['suites'], [canonical])

    def test_hidden_loader_requires_exact_raw_path_and_loading_metadata(self):
        canonical = 'test/dart_flutter_test.dart'
        for target, path in [('linux-x64', canonical),
                             ('windows-x64', canonical.replace('/', '\\'))]:
            mutations = [
                lambda test: test.update(name='loading test/other_test.dart'),
                lambda test: test.update(name='loading ' + canonical.replace('/', '\\')
                                        if target == 'linux-x64' else 'loading ' + canonical),
                lambda test: test.update(name='loading ' + path + ' '),
                lambda test: test.update(name='loading test/../' + path),
                lambda test: test.update(groupIDs=[0]),
                lambda test: test.update(url='file:///test.dart'),
            ]
            for index, mutate in enumerate(mutations):
                with self.subTest(target=target, mutation=index):
                    records = self.hidden_loader_events(path)
                    mutate(records[3]['test'])
                    with self.assertRaisesRegex(ValueError, 'Unexpected hidden'):
                        summarize_tests(records, {canonical}, target)
            for key, value in [('result', 'failure'), ('result', 'error'), ('skipped', True)]:
                with self.subTest(target=target, key=key, value=value):
                    records = self.hidden_loader_events(path)
                    records[4][key] = value
                    with self.assertRaises(ValueError):
                        summarize_tests(records, {canonical}, target)

    def test_exact_loader_cannot_admit_noncanonical_suite_inventory(self):
        canonical = 'test/dart_flutter_test.dart'
        for path in ('test/../' + canonical, './' + canonical, '/' + canonical,
                     'test//dart_flutter_test.dart', 'test\\..\\test\\dart_flutter_test.dart',
                     'C:\\test\\dart_flutter_test.dart', canonical + '\x00'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                summarize_tests(self.hidden_loader_events(path), {canonical}, 'windows-x64')

    def test_hidden_user_test_cannot_mask_execution(self):
        path = 'test/dart_flutter_test.dart'
        for skipped in (False, True):
            records = events(path, skipped=skipped)
            records[2]['hidden'] = True
            with self.assertRaises(ValueError):
                summarize_tests(records, {path}, 'linux-x64')

    def test_declared_or_load_only_suite_does_not_count_as_execution(self):
        path, other = 'test/dart_flutter_test.dart', 'test/cli_test.dart'
        for load in (False, True):
            records = events(path)[:-1]
            records.append({'type': 'suite', 'suite': {'id': 2, 'path': other}})
            if load:
                records.extend([
                    {'type': 'testStart', 'test': {'id': 3, 'suiteID': 2,
                     'name': 'loading ' + other, 'groupIDs': [], 'url': None,
                     'metadata': {'skip': False, 'skipReason': None}}},
                    {'type': 'testDone', 'testID': 3, 'result': 'success',
                     'hidden': True, 'skipped': False}])
            records.append({'type': 'done', 'success': True})
            with self.assertRaises(ValueError):
                summarize_tests(records, {path, other}, 'linux-x64')

    def test_optional_fixture_skip_is_never_accepted(self):
        path = 'test/dart_flutter_test.dart'
        with self.assertRaisesRegex(ValueError, 'Unapproved source test skip'):
            summarize_tests(events(path, skipped=True), {path}, 'linux-x64')

    def test_linux_socket_capability_skip_does_not_qualify(self):
        path = 'test/dart_adversarial_test.dart'
        records = events(path, skipped=True,
            name='a stable socket entry outside scope does not change inventory identity')
        records[1]['test']['metadata']['skipReason'] = None
        records.insert(2, {'type': 'print', 'testID': 1, 'messageType': 'skip',
                           'message': 'Host refuses Unix-domain server socket binding (errno 9).'})
        with self.assertRaisesRegex(ValueError, 'Unapproved source test skip.*socket'):
            summarize_tests(records, {path}, 'linux-x64')

    def test_missing_suite_or_terminal_record_is_not_a_pass(self):
        path = 'test/dart_flutter_test.dart'
        for records, expected in [(events(path), {path, 'test/missing_test.dart'}),
                                   (events(path)[:-1], {path})]:
            with self.assertRaises(ValueError):
                summarize_tests(records, expected, 'linux-x64')

    def test_observed_filesystem_capability_guard_keeps_its_reason(self):
        path = 'test/physical_paths_test.dart'
        records = events(path, skipped=True,
            name='case-insensitive source lookup does not relax exact scope spelling')
        records[1]['test']['metadata']['skipReason'] = None
        records.insert(2, {'type': 'print', 'testID': 1, 'messageType': 'skip',
                           'message': 'Requires a case-insensitive filesystem.'})
        report = summarize_tests(records, {path}, 'linux-x64')
        self.assertEqual(report['skipped'][0]['reason'], 'Requires a case-insensitive filesystem.')
        records[2]['message'] = 'fixture missing'
        with self.assertRaisesRegex(ValueError, 'Unapproved source test skip'):
            summarize_tests(records, {path}, 'linux-x64')

    def test_existing_target_guard_is_reported_explicitly(self):
        path = 'test/windows_native_probe_test.dart'
        report = summarize_tests(events(path, skipped=True,
            name='Windows x64 CLI init creates both files in a fresh root'), {path}, 'linux-x64')
        self.assertEqual(report['passed'], 0)
        self.assertEqual(report['skipped'][0]['file'], path)
        with self.assertRaisesRegex(ValueError, 'Unapproved source test skip'):
            summarize_tests(events(path, skipped=True,
                name='Windows x64 CLI init creates both files in a fresh root'), {path}, 'windows-x64')


if __name__ == '__main__':
    unittest.main()
