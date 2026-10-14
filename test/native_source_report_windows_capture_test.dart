import 'package:test/test.dart';

import '../tool/ci/native_source_report.dart';

void main() {
  test('Windows stdin skip evidence requires the exact case host and reason', () {
    const path = 'test/native_acceptance_windows_stdin_test.dart';
    for (final name in [
      'Windows stdin options reject unsupported hosts before launch',
      'Windows file stdin preserves exact bytes and EOF through suite capture',
      'Windows file stdin rejects invalid inputs and releases failed spawn handles',
      'Windows file stdin retains the restricted inherited handle list',
    ]) {
      final unsupported =
          name ==
          'Windows stdin options reject unsupported hosts before launch';
      final reason = unsupported
          ? 'Non-Windows stdin host control.'
          : 'Native Windows file stdin control.';
      for (final target in sourceTargets) {
        final report = () => summarizeTests(
          [
            {
              'type': 'suite',
              'suite': {'id': 0, 'path': path},
            },
            {
              'type': 'testStart',
              'test': {
                'id': 1,
                'suiteID': 0,
                'name': name,
                'metadata': {'skipReason': reason},
              },
            },
            {
              'type': 'testDone',
              'testID': 1,
              'result': 'success',
              'skipped': true,
              'hidden': false,
            },
            {'type': 'done', 'success': true},
          ],
          {path},
          target,
        );
        if ((target == 'windows-x64') == unsupported) {
          expect((report()['skipped'] as List).single['reason'], reason);
          for (final wrong in [null, '', 'dependency missing', '$reason ']) {
            expect(expectedSkip(target, path, name, wrong), isFalse);
          }
          expect(expectedSkip(target, '$path.other', name, reason), isFalse);
          expect(expectedSkip(target, path, '$name changed', reason), isFalse);
        } else {
          expect(report, throwsFormatException);
        }
      }
    }
  });
  test('Windows job skip evidence requires the exact case host and reason', () {
    const path = 'test/native_acceptance_windows_job_test.dart';
    for (final name in [
      'Windows job completion rejects unsupported hosts before launch',
      for (final scenario in [
        'silent',
        'retained',
        'nonzero',
        'timeout',
        'opt-out',
      ])
        'Windows owned job completion: $scenario',
    ]) {
      final unsupported =
          name ==
          'Windows job completion rejects unsupported hosts before launch';
      final reason = unsupported
          ? 'Non-Windows job completion host control.'
          : 'Native Windows owned job completion control.';
      for (final target in sourceTargets) {
        final report = () => summarizeTests(
          [
            {
              'type': 'suite',
              'suite': {'id': 0, 'path': path},
            },
            {
              'type': 'testStart',
              'test': {
                'id': 1,
                'suiteID': 0,
                'name': name,
                'metadata': {'skipReason': reason},
              },
            },
            {
              'type': 'testDone',
              'testID': 1,
              'result': 'success',
              'skipped': true,
              'hidden': false,
            },
            {'type': 'done', 'success': true},
          ],
          {path},
          target,
        );
        if ((target == 'windows-x64') == unsupported) {
          expect((report()['skipped'] as List).single['reason'], reason);
          for (final wrong in [null, '', 'dependency missing', '$reason ']) {
            expect(expectedSkip(target, path, name, wrong), isFalse);
          }
          expect(expectedSkip(target, '$path.other', name, reason), isFalse);
          expect(expectedSkip(target, path, '$name changed', reason), isFalse);
        } else {
          expect(report, throwsFormatException);
        }
      }
    }
  });
}
