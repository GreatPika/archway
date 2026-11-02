// Native Windows acceptance for genuine CTRL_C and bounded sender ownership.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'support/process_lifecycle.dart';
import 'support/windows_console.dart';
import 'support/windows_job.dart';
import 'support/windows_process.dart';
import 'support/windows_process_pipes.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// These markers are unique within the owned temporary directory. Publish only
// after writing and closing a same-directory file; existence means complete.
void publishReady(File marker, String contents) {
  final pending = File('${marker.path}.pending');
  pending.writeAsStringSync(contents, flush: true);
  pending.renameSync(marker.path);
}

Future<void> ready(File marker) async {
  final elapsed = Stopwatch()..start();
  while (!marker.existsSync()) {
    check(
      elapsed.elapsed < const Duration(seconds: 10),
      'Missing ${marker.path}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> compile(String source, String destination) async {
  WindowsJob? job;
  WindowsSuspendedProcess? process;
  WindowsProcessPipes? pipes;
  try {
    job = WindowsJob();
    pipes = WindowsProcessPipes();
    process = job.spawn([
      Platform.resolvedExecutable,
      '--suppress-analytics',
      'compile',
      'exe',
      source,
      '-o',
      destination,
    ], output: pipes);
    final result = await pipes.communicate(
      () => process!.exitCode,
      const Duration(seconds: 60),
    );
    check(
      result.exitCode == 0,
      'Fixture compile failed: ${utf8.decode(result.stderr, allowMalformed: true)}',
    );
  } finally {
    try {
      job?.close();
    } finally {
      try {
        process?.close();
      } finally {
        pipes?.close();
      }
    }
  }
}

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  if (arguments.isNotEmpty) {
    final marker = File(arguments[1]);
    if (arguments.first == 'target') {
      ProcessSignal.sigint.watch().listen((_) => exit(23));
      publishReady(marker, jsonEncode(windowsConsoleMembers()));
    } else if (arguments.first == 'hold') {
      final child = await Process.start(Platform.resolvedExecutable, [
        'hold-child',
        '${marker.path}.child',
      ]);
      await ready(File('${marker.path}.child'));
      publishReady(marker, jsonEncode([pid, child.pid]));
    } else if (arguments.first == 'hold-child') {
      publishReady(marker, '$pid');
    } else {
      throw ArgumentError('Unknown fixture role');
    }
    Timer.periodic(const Duration(seconds: 1), (_) {});
    await Completer<void>().future;
    return;
  }
  final root = Directory.systemTemp.createTempSync('archway-console-');
  try {
    final fixture = '${root.path}\\fixture.exe';
    final sender = '${root.path}\\sender.exe';
    await compile('test/windows_console_capability.dart', fixture);
    await compile('test/support/windows_console_sender.dart', sender);
    final before = windowsConsoleMembers();
    WindowsJob? job;
    WindowsSuspendedProcess? target;
    WindowsProcessPipes? pipes;
    try {
      job = WindowsJob();
      pipes = WindowsProcessPipes();
      final marker = File('${root.path}\\ready');
      setWindowsCtrlCIgnored(
        true,
      ); // Independent inherited-ignore precondition.
      target = startWindowsInterruptible(job, [
        fixture,
        'target',
        marker.path,
      ], output: pipes);
      await ready(marker);
      check(
        isProcessAlive(target.pid) && target.exitCode == null,
        'Target is not alive',
      );
      final targetMembers = jsonDecode(marker.readAsStringSync()) as List;
      check(
        targetMembers.contains(target.pid) && !targetMembers.contains(pid),
        'Target shares harness console',
      );
      final witness = jsonDecode(
        await runWindowsConsoleSender([sender, '${target.pid}']),
      ) as Map;
      final members = witness['members'] as List;
      check(
        members.contains(target.pid) &&
            members.contains(witness['sender']) &&
            !members.contains(pid),
        'Sender did not attach only to target console',
      );
      final result = await pipes.communicate(
        () => target!.exitCode,
        const Duration(seconds: 10),
      );
      // Observe cancellation before closing the Job, so cleanup cannot fake it.
      check(
        result.exitCode == 23 && result.stdout.isEmpty && result.stderr.isEmpty,
        'CTRL_C did not produce exact exit23 with silent EOF',
      );
      check(!isProcessAlive(target.pid), 'Interrupted target remains alive');
      check(
        jsonEncode(windowsConsoleMembers()) == jsonEncode(before),
        'Harness console association changed',
      );
      stdout.writeln(
        'LifecycleSupportTest.test_real_ctrl_c_reports_and_exits passed',
      );
      final elapsed = Stopwatch()..start();
      var failed = false;
      try {
        await runWindowsConsoleSender([sender, '${target.pid}']);
      } on StateError catch (error) {
        failed =
            error.toString().contains('AttachConsole') &&
            error.toString().contains('OS Error');
      }
      check(
        failed && elapsed.elapsed < const Duration(seconds: 10),
        'Dead target did not fail with bounded native diagnostics',
      );
      stdout.writeln('Windows console dead-target diagnostic passed');
    } finally {
      try {
        job?.close();
      } finally {
        try {
          target?.close();
        } finally {
          pipes?.close();
        }
      }
    }
    await heldSender(fixture, File('${root.path}\\held'));
  } finally {
    root.deleteSync(recursive: true);
  }
}

Future<void> heldSender(String fixture, File marker) async {
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
  final handles = <Pointer<Void>>[];
  final elapsed = Stopwatch()..start();
  // Observe errors immediately while acquiring retained handles before cleanup.
  final sending = runWindowsConsoleSender([fixture, 'hold', marker.path])
      .then<Object?>((_) => null, onError: (Object failure) => failure);
  try {
    await ready(marker);
    for (final child in jsonDecode(marker.readAsStringSync()) as List) {
      final handle = open(0x100000, 0, child as int);
      if (handle == nullptr) throw OSError('OpenProcess held sender', error());
      handles.add(handle);
      check(wait(handle, 0) == 258, 'Held sender tree not alive');
    }
    final result = await sending;
    check(
      result is WindowsPipeTimeout,
      'Held sender did not reach its deadline: $result',
    );
    check(
      elapsed.elapsed < const Duration(seconds: 12),
      'Sender cleanup exceeded bounded deadline',
    );
    check(
      handles.length == 2 && handles.every((handle) => wait(handle, 0) == 0),
      'Sender tree not reaped on retained handles',
    );
    stdout.writeln('Windows console held-sender tree cleanup passed');
  } finally {
    await sending; // Cleanup completes even when witness acquisition fails.
    Object? failure;
    for (final handle in handles) {
      if (close(handle) == 0)
        failure ??= OSError('CloseHandle witness', error());
    }
    if (failure != null) throw failure;
  }
}
