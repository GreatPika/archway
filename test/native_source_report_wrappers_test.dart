import 'package:test/test.dart';

import '../tool/ci/native_source_report.dart';

void main() {
  test('thin-wrapper applicability requires exact declaration host and reason', () {
    const cases = <(String, String, String, String)>[
      (
        'windows',
        'test/npm_windows_shim_native_test.dart',
        'actual npm local global and exec Windows shims preserve literal argv under owned capture',
        'Requires genuine Windows npm shims and owned raw-command execution.',
      ),
      (
        'windows',
        'test/windows_raw_command_test.dart',
        'native raw cmd preserves builtin streams exit and execution metadata',
        'Requires native Windows cmd and Job ownership.',
      ),
      (
        'windows',
        'test/process_lifecycle_test.dart',
        'owned Windows handle preserves exit 23 after direct-child reap',
        'Requires native Windows owned process handles.',
      ),
      (
        'linux',
        'test/npm_archive_test.dart',
        'ZIP output creation failure releases the open member input',
        'Linux descriptor observation; other hosts retain extraction controls',
      ),
      (
        'posix',
        'test/npm_stage_test.dart',
        'packer rejects altered npm-produced payload and removes its owned temporary output',
        'Packaging owner runs on POSIX; fixture executable uses a shebang.',
      ),
      (
        'posix',
        'test/windows_raw_command_test.dart',
        'raw Windows capture rejects unsupported host before reserving evidence',
        'Non-Windows admission control.',
      ),
      (
        'posix',
        'test/pub_dart_bootstrap_test.dart',
        'bootstrap refuses wrong official SDK bytes before extraction or executable dispatch',
        'POSIX shell admission control; native Windows bootstrap is a CI gate',
      ),
      (
        'posix',
        'test/package_delivery_dispatch_test.dart',
        'npm workflow forwards closed arguments and preserves CLI failure through tee',
        'POSIX shell dispatch; native Windows workflow remains required',
      ),
      (
        'posix',
        'test/package_delivery_dispatch_test.dart',
        'pub workflow forwards closed arguments and preserves CLI failure through tee',
        'POSIX shell dispatch; native Windows workflow remains required',
      ),
      (
        'posix',
        'test/package_delivery_workflow_test.dart',
        'malformed transport cannot publish a successful workflow output',
        'POSIX shell output guard; native host workflow remains required',
      ),
    ];
    for (final (host, path, name, reason) in cases) {
      for (final target in sourceTargets) {
        final allowed = switch (host) {
          'windows' => target != 'windows-x64',
          'linux' => target != 'linux-x64',
          'posix' => target == 'windows-x64',
          _ => false,
        };
        expect(
          expectedSkip(target, path, name, reason),
          allowed,
          reason: '$target $path $name',
        );
        for (final wrong in [null, '', 'dependency missing', '$reason ']) {
          expect(expectedSkip(target, path, name, wrong), isFalse);
        }
        expect(expectedSkip(target, '$path.other', name, reason), isFalse);
        expect(expectedSkip(target, path, '$name changed', reason), isFalse);
        final events = <Map<String, dynamic>>[
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
        ];
        if (allowed) {
          expect(
            (summarizeTests(events, {path}, target)['skipped'] as List)
                .single['reason'],
            reason,
          );
        } else {
          expect(
            () => summarizeTests(events, {path}, target),
            throwsFormatException,
          );
        }
        expect(
          () => summarizeTests([events.first, events.last], {path}, target),
          throwsFormatException,
        );
      }
    }
  });
}
