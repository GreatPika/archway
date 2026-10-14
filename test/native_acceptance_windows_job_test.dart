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
  // Separate teardowns let the runner retain the scenario failure and every
  // cleanup failure, while still attempting all cleanup in reverse order.
  addTearDown(() => root.deleteSync(recursive: true));
  addTearDown(() => descendant?.close());
  addTearDown(() => parent?.close());
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
  addTearDown(() async {
    await outcome;
  });
  addTearDown(() => File('${marker}.descendant-release').createSync());
  addTearDown(() => File('${marker}.parent-release').createSync());
  int? readPublishedPid(String role) {
    final file = File('$marker.$role');
    if (!file.existsSync()) return null;
    try {
      return int.parse(file.readAsStringSync());
    } on FileSystemException catch (error) {
      // Atomic publication closes the writer, but an existing Windows file can
      // still have a transient sharing conflict. Readability is part of the
      // same bounded readiness barrier; malformed PIDs and other errors fail.
      if (error.osError?.errorCode != 32) rethrow;
      return null;
    }
  }

  int? parentPid, descendantPid;
  await waitUntil(() {
    parentPid ??= readPublishedPid('parent');
    descendantPid ??= readPublishedPid('descendant');
    return parentPid != null && descendantPid != null;
  });
  parent = NativeWitness(parentPid!);
  descendant = NativeWitness(descendantPid!);
  expect(parent.exited, isFalse);
  expect(descendant.exited, isFalse);
  File('${marker}.parent-release').createSync();
  await waitUntil(() => parent!.exited);
  if (waitForJob) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      completed,
      isFalse,
      reason:
          'A live owned descendant must delay completion even after both EOFs',
    );
    expect(descendant.exited, isFalse);
    if (scenario != 'timeout')
      File('${marker}.descendant-release').createSync();
  }
  final result = await outcome;
  // Forced termination can precede process-handle signalling. Observe the
  // retained handle before any release marker or fallback kill can mask a leak.
  expect(
    scenario == 'timeout' || scenario == 'opt-out'
        ? descendant.waitForExit()
        : descendant.exited,
    isTrue,
  );
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
}

// A PID only locates the process while a barrier holds it alive. All subsequent
// observations and emergency cleanup use this exact retained native handle.
final class NativeWitness {
  NativeWitness(this.pid) : handle = open(0x00100001, 0, pid) {
    if (handle == nullptr)
      throw OSError('Cannot retain native process witness', lastError());
  }
  static late final int Function() lastError;
  static final api = loadApi();
  static DynamicLibrary loadApi() {
    final library = DynamicLibrary.open('kernel32.dll');
    // Resolve before fallible calls: symbol lookup can change last-error.
    lastError = library.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    return library;
  }

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
  final int pid;
  final Pointer<Void> handle;
  bool get exited => _waitForExit(0);

  bool waitForExit() => _waitForExit(5000);

  bool _waitForExit(int milliseconds) {
    final state = wait(handle, milliseconds);
    final error = state == 0xffffffff ? lastError() : null;
    if (state != 0 && state != 258)
      throw StateError('Native witness wait failed: state=$state error=$error');
    return state == 0;
  }

  void close() {
    final initial = wait(handle, 0);
    final initialError = initial == 0xffffffff ? lastError() : null;
    int? terminated, terminationError, waited, waitError;
    if (initial != 0) {
      terminated = terminate(handle, 1);
      terminationError = terminated == 0 ? lastError() : null;
      // A refused request can race with termination already in progress. Only
      // this retained handle becoming signalled confirms cleanup.
      waited = wait(handle, 5000);
      waitError = waited == 0xffffffff ? lastError() : null;
    }
    final closed = release(handle);
    final closeError = closed == 0 ? lastError() : null;
    final evidence =
        'pid=$pid initial=$initial initialError=$initialError '
        'terminate=$terminated terminationError=$terminationError '
        'wait=$waited waitError=$waitError close=$closed closeError=$closeError';
    if ((initial != 0 && waited != 0) || closed == 0) {
      throw StateError('Native witness cleanup unconfirmed: $evidence');
    }
    print('Native witness cleanup confirmed: $evidence');
  }
}
