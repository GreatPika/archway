import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/native_acceptance_capture.dart';

void main() {
  test(
    'Windows capture timeout survives every cleanup failure with its stack',
    () async {
      final timeout = TimeoutException(
        'original capture deadline',
        const Duration(seconds: 3),
      );
      final originalStack = StackTrace.fromString(
        'original Windows capture stack',
      );
      final calls = <String>[];
      final diagnostics = <(Object, StackTrace)>[];
      final failures = [
        StateError('job cleanup unconfirmed'),
        StateError('child close failed'),
        StateError('pipe close failed'),
      ];
      void close(int index) {
        calls.add(['job', 'child', 'pipes'][index]);
        throw failures[index];
      }

      try {
        await captureWithWindowsOwners(
          capture: () async =>
              Error.throwWithStackTrace(timeout, originalStack),
          closeJob: () => close(0),
          closeChild: () => close(1),
          closePipes: () => close(2),
          reportCleanupFailure: (error, stack) =>
              diagnostics.add((error, stack)),
        );
        fail('Capture unexpectedly succeeded');
      } catch (error, stack) {
        expect(error, same(timeout));
        expect(
          error,
          isA<TimeoutException>(),
        ); // executeSuite retains timed_out:true.
        expect(stack.toString(), originalStack.toString());
      }
      expect(calls, ['job', 'child', 'pipes']);
      expect(diagnostics.map((failure) => failure.$1), orderedEquals(failures));
      expect(
        diagnostics.every((failure) => failure.$2.toString().isNotEmpty),
        isTrue,
      );
    },
  );
  test('Windows cleanup failure rejects successful capture and preserves the first close stack', () async {
    final first = StateError('job cleanup unconfirmed');
    final originalStack = StackTrace.fromString('first cleanup stack');
    final second = StateError('child close failed');
    final calls = <String>[], diagnostics = <Object>[];
    try {
      await captureWithWindowsOwners(
        capture: () async => 0,
        closeJob: () {
          calls.add('job');
          Error.throwWithStackTrace(first, originalStack);
        },
        closeChild: () {
          calls.add('child');
          throw second;
        },
        closePipes: () => calls.add('pipes'),
        reportCleanupFailure: (error, stack) => diagnostics.add(error),
      );
      fail('Cleanup failure was accepted as capture success');
    } catch (error, stack) {
      expect(error, same(first));
      expect(error, isNot(isA<TimeoutException>()));
      expect(stack.toString(), originalStack.toString());
    }
    expect(calls, ['job', 'child', 'pipes']);
    expect(diagnostics, [same(second)]);
  });

  test('Windows diagnostic sink failure cannot replace capture failure or skip a closer', () async {
    final first = StateError('original capture failure');
    final calls = <String>[];
    await expectLater(
      captureWithWindowsOwners(
        capture: () async => throw first,
        closeJob: () {
          calls.add('job');
          throw StateError('job failure');
        },
        closeChild: () {
          calls.add('child');
          throw StateError('child failure');
        },
        closePipes: () => calls.add('pipes'),
        reportCleanupFailure: (error, stack) {
          calls.add('report');
          throw StateError('diagnostic sink failure');
        },
      ),
      throwsA(same(first)),
    );
    expect(calls, ['job', 'report', 'child', 'report', 'pipes']);
  });

  test(
    'Windows capture success retains the exit only after every owner closes',
    () async {
      final calls = <String>[];
      expect(
        await captureWithWindowsOwners(
          capture: () async {
            calls.add('capture');
            return 7;
          },
          closeJob: () => calls.add('job'),
          closeChild: () => calls.add('child'),
          closePipes: () => calls.add('pipes'),
          reportCleanupFailure: (error, stack) =>
              fail('Unexpected cleanup diagnostic'),
        ),
        7,
      );
      expect(calls, ['capture', 'job', 'child', 'pipes']);
    },
  );

  test('Windows cleanup diagnostics use invoking stderr and retain the primary failure', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'run',
      'test/support/windows_acceptance_cleanup_probe.dart',
    ]);
    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, 'original timeout retained');
    expect(
      result.stderr,
      contains(
        'Windows acceptance cleanup unconfirmed: Bad state: injected job cleanup failure',
      ),
    );
  });
}
