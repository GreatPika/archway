import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_acceptance.dart';
import '../tool/ci/native_acceptance_capture.dart';

void main() {
  test('Windows capture spends one deadline and rejects success at expiry', () {
    const timeout = Duration(milliseconds: 100);
    expect(windowsCaptureRemaining(timeout, Duration.zero), timeout);
    expect(
      windowsCaptureRemaining(timeout, const Duration(milliseconds: 70)),
      const Duration(milliseconds: 30),
    );
    for (final elapsed in [timeout, const Duration(milliseconds: 101)]) {
      expect(
        () => windowsCaptureRemaining(timeout, elapsed),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.duration,
            'original budget',
            timeout,
          ),
        ),
      );
    }
  });
  test(
    'Windows job completion rejects unsupported hosts before launch',
    () async {
      final root = Directory.systemTemp.createTempSync('acceptance-job-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = File(p.join(root.path, 'output'))
          .openSync(mode: FileMode.write);
      addTearDown(output.closeSync);
      await expectLater(
        captureAcceptanceProcess(
          [Platform.resolvedExecutable, '--version'],
          root.path,
          Platform.environment,
          output,
          output,
          const Duration(seconds: 5),
          waitForWindowsJobEmpty: true,
        ),
        throwsUnsupportedError,
      );
      await expectLater(
        executeSuite(
          'unsupported',
          [Platform.resolvedExecutable, '--version'],
          root.path,
          Platform.environment,
          root,
          waitForWindowsJobEmpty: true,
        ),
        throwsUnsupportedError,
      );
      expect(
        File(p.join(root.path, 'unsupported.stdout.log')).readAsBytesSync(),
        isEmpty,
      );
    },
    skip: Platform.isWindows
        ? 'Non-Windows job completion host control.'
        : false,
  );

  for (final scenario in [
    'silent',
    'retained',
    'nonzero',
    'timeout',
    'opt-out',
  ]) {
    test(
      'Windows owned job completion: ${scenario}',
      () => runScenario(scenario),
      timeout: const Timeout(Duration(seconds: 45)),
      skip: !Platform.isWindows
          ? 'Native Windows owned job completion control.'
          : false,
    );
  }
}

Future<void> waitUntil(bool Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed >= const Duration(seconds: 10))
      throw TimeoutException('Missing native capture barrier');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> runScenario(String scenario) async {
  final root = Directory.systemTemp.createTempSync('acceptance-job-');
  final marker = p.join(root.path, 'ready');
  NativeWitness? parent, descendant;
  var completed = false;
  final waitForJob = scenario != 'opt-out';
  final timeout = Duration(seconds: scenario == 'timeout' ? 10 : 30);
  final clock = Stopwatch()..start();
  final outcome =
      executeSuite(
        'capture',
        [
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'run',
          File('test/support/windows_acceptance_job_child.dart').absolute.path,
          'parent',
          marker,
          scenario == 'retained' ? 'retained' : 'silent',
          scenario == 'nonzero' ? '7' : '0',
        ],
        root.path,
        Platform.environment,
        root,
        timeout: timeout,
        waitForWindowsJobEmpty: waitForJob,
      ).then<Object>(
        (value) {
          completed = true;
          return value;
        },
        onError: (Object error) {
          completed = true;
          return error;
        },
      );
  try {
    await waitUntil(
      () =>
          File('${marker}.parent').existsSync() &&
          File('${marker}.descendant').existsSync(),
    );
    parent = NativeWitness(
      int.parse(File('${marker}.parent').readAsStringSync()),
    );
    descendant = NativeWitness(
      int.parse(File('${marker}.descendant').readAsStringSync()),
    );
    expect(parent.exited, isFalse);
    expect(descendant.exited, isFalse);
    File('${marker}.parent-release').createSync();
    await waitUntil(() => parent!.exited);
    if (waitForJob) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        completed,
        isFalse,
        reason: 'A live owned descendant must delay completion even after both EOFs',
      );
      expect(descendant.exited, isFalse);
      if (scenario != 'timeout')
        File('${marker}.descendant-release').createSync();
    }
    final result = await outcome;
    // Check the retained handle before any fallback cleanup can mask a leak.
    expect(descendant.exited, isTrue);
    expect(parent.exited, isTrue);
    if (scenario == 'timeout') {
      expect(result, isA<TimeoutException>());
      expect(clock.elapsed, lessThan(const Duration(seconds: 17)));
    } else if (scenario == 'nonzero') {
      expect(result, isA<SuiteExitFailure>());
      expect((result as SuiteExitFailure).proof['exit_code'], 7);
    } else {
      expect((result as Map)['exit_code'], 0);
    }
    expect(
      File(p.join(root.path, 'capture.stdout.log')).readAsStringSync(),
      'parent\n',
    );
    expect(
      File(p.join(root.path, 'capture.stderr.log')).readAsStringSync(),
      'descendant\n',
    );
  } finally {
    File('${marker}.parent-release').createSync();
    File('${marker}.descendant-release').createSync();
    try {
      await outcome;
    } finally {
      try {
        parent?.close();
      } finally {
        try {
          descendant?.close();
        } finally {
          root.deleteSync(recursive: true);
        }
      }
    }
  }
}

// A PID only locates the process while a barrier holds it alive. All subsequent
// observations and emergency cleanup use this exact retained native handle.
final class NativeWitness {
  NativeWitness(int pid) : handle = open(0x00100001, 0, pid) {
    if (handle == nullptr)
      throw StateError('Cannot retain native process witness');
  }
  static final api = DynamicLibrary.open('kernel32.dll');
  static final open = api
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  static final wait = api
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  static final terminate = api
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('TerminateProcess');
  static final release = api
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final Pointer<Void> handle;
  bool get exited {
    final state = wait(handle, 0);
    if (state != 0 && state != 258)
      throw StateError('Native witness wait failed: ${state}');
    return state == 0;
  }

  void close() {
    try {
      if (!exited) {
        if (terminate(handle, 1) == 0 || wait(handle, 5000) != 0)
          throw StateError('Native witness cleanup unconfirmed');
      }
    } finally {
      if (release(handle) == 0) throw StateError('Native witness close failed');
    }
  }
}
