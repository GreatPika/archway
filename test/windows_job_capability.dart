// Explicit native Windows job ownership scenarios, never a skipped certificate.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'support/windows_job.dart';
import 'support/process_lifecycle.dart';
import 'support/windows_process.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> waitForFile(File file, Duration timeout) async {
  final elapsed = Stopwatch()..start();
  while (!file.existsSync()) {
    if (elapsed.elapsed >= timeout)
      throw TimeoutException('Missing ${file.path}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> verifyReadinessFailure(String failure, File ready) async {
  if (failure == 'before-readiness') {
    check(!ready.existsSync(), 'Unexpected readiness marker');
    try {
      throw TimeoutException('Injected readiness deadline');
    } on TimeoutException {
      return;
    }
  }
  // A missing marker is a broken fixture, not evidence of malformed JSON.
  await waitForFile(ready, const Duration(seconds: 5));
  try {
    jsonDecode(ready.readAsStringSync());
  } on FormatException {
    return;
  }
  throw StateError('Malformed readiness did not cause a parse error');
}

Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  final child = File('test/support/process_fixture_child.dart').absolute.path;
  for (final failure in ['assignment', 'resume']) {
    WindowsSuspendedProcess? created;
    WindowsSuspendedProcess? returned;
    final job = WindowsJob(
      assignProcess: failure == 'assignment'
          ? (process) {
              created = process;
              throw StateError('Injected assignment failure');
            }
          : null,
      resumeProcess: failure == 'resume'
          ? (process) {
              created = process;
              throw StateError('Injected resume failure');
            }
          : null,
    );
    try {
      var rejected = false;
      try {
        returned = job.spawn([
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'run',
          child,
        ]);
      } on StateError {
        rejected = true;
      }
      // Assert automatic cleanup BEFORE fallback cleanup can mask a regression.
      check(rejected, '$failure injection was ignored');
      check(
        created != null && created!.exitCode != null,
        'Suspended child was not reaped',
      );
      check(!isProcessAlive(created!.pid), 'Failed child is still alive');
      check(job.isClosed, 'Failed spawn retained the job');
    } finally {
      try {
        job.close();
      } finally {
        try {
          returned?.close();
        } finally {
          created?.close();
        }
      }
    }
  }
  stdout.writeln(
    'WindowsJobTests.test_assignment_and_resume_failures_reap_suspended_process passed',
  );

  // Independent retained SYNCHRONIZE handle proves descendant exit, not PID reuse.
  final api = DynamicLibrary.open('kernel32.dll');
  final error = api.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final open = api
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  final wait = api
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  final close = api
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final query = api
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
      >('QueryInformationJobObject');
  for (final failure in ['before-readiness', 'malformed-readiness']) {
    final root = Directory.systemTemp.createTempSync('archway-job-');
    final witness = File('${root.path}\\child.pid');
    final ready = File('${root.path}\\ready.json');
    WindowsSuspendedProcess? process;
    Pointer<Void> descendant = nullptr;
    try {
      final job = WindowsJob();
      try {
        final limits = calloc<Uint8>(144);
        try {
          if (query(job.nativeHandle, 9, limits.cast(), 144, nullptr) == 0) {
            throw OSError('QueryInformationJobObject limits', error());
          }
          check(
            (limits + 16).cast<Uint32>().value == 0x2000,
            'Job must enable KILL_ON_JOB_CLOSE without any breakaway flags',
          );
        } finally {
          calloc.free(limits);
        }
        process = job.spawn([
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'run',
          File('test/support/windows_job_child.dart').absolute.path,
          witness.path,
          ready.path,
          failure,
          child,
        ]);
        await waitForFile(witness, const Duration(seconds: 10));
        descendant = open(0x00100000, 0, int.parse(witness.readAsStringSync()));
        if (descendant == nullptr)
          throw OSError('OpenProcess descendant', error());
        check(
          job.activeProcessCount >= 2,
          'Job did not account for descendant',
        );
        await verifyReadinessFailure(failure, ready);
      } finally {
        try {
          job.close();
        } finally {
          try {
            if (descendant != nullptr) {
              check(
                wait(descendant, 5000) == 0,
                'Owned descendant exit unconfirmed',
              );
            }
          } finally {
            try {
              process?.close();
            } finally {
              if (descendant != nullptr && close(descendant) == 0) {
                throw OSError('CloseHandle descendant', error());
              }
            }
          }
        }
      }
      check(process.exitCode != null, 'Owned parent exit unconfirmed');
      check(job.isClosed, 'Closed job retained its handle');
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  stdout.writeln(
    'WindowsJobTests.test_pre_readiness_timeout_and_malformed_marker_clean_owned_tree passed',
  );
}
