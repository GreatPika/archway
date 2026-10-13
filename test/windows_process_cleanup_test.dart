import 'dart:io';

import 'package:test/test.dart';

import 'support/windows_process.dart';

void main() {
  test('termination race confirms and preserves the actual exit code', () {
    final calls = <String>[];
    final result = confirmWindowsProcessTermination(
      terminate: () {
        calls.add('terminate');
        return const OSError('TerminateProcess', 5);
      },
      wait: (milliseconds) {
        calls.add('wait:$milliseconds');
        return 0; // The same process exited between running probe and termination.
      },
      readExitCode: () {
        calls.add('exit');
        return 23;
      },
    );
    expect(result, 23);
    expect(calls, ['terminate', 'wait:5000', 'exit']);
  });

  test('unconfirmed termination preserves the original native error', () {
    const failure = OSError('TerminateProcess', 5);
    for (final state in [258]) {
      expect(
        () => confirmWindowsProcessTermination(
          terminate: () => failure,
          wait: (_) => state,
          readExitCode: () =>
              throw StateError('Unconfirmed exit must not be read'),
        ),
        throwsA(same(failure)),
      );
    }
    expect(
      () => confirmWindowsProcessTermination(
        terminate: () => failure,
        wait: (_) => throw const OSError('WaitForSingleObject', 6),
        readExitCode: () =>
            throw StateError('Unconfirmed exit must not be read'),
      ),
      throwsA(same(failure)),
    );
  });
}
