// Developer-only genuine CTRL_C delivery, isolated from the harness console.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'windows_job.dart';
import 'windows_process.dart';
import 'windows_process_pipes.dart';

late final int Function() _error;
final _kernel = _loadKernel();
DynamicLibrary? _loadKernel() {
  if (!Platform.isWindows) return null;
  final api = DynamicLibrary.open('kernel32.dll');
  _error = api.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  return api;
}

final _handler = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('SetConsoleCtrlHandler');
final _free = _kernel?.lookupFunction<Int32 Function(), int Function()>(
  'FreeConsole',
);
final _attach = _kernel
    ?.lookupFunction<Int32 Function(Uint32), int Function(int)>(
      'AttachConsole',
    );
final _generate = _kernel
    ?.lookupFunction<Int32 Function(Uint32, Uint32), int Function(int, int)>(
      'GenerateConsoleCtrlEvent',
    );
final _members = _kernel
    ?.lookupFunction<
      Uint32 Function(Pointer<Uint32>, Uint32),
      int Function(Pointer<Uint32>, int)
    >('GetConsoleProcessList');
Never _fail(String operation) => throw OSError(operation, _error());

void setWindowsCtrlCIgnored(bool ignored) {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  if (_handler!(nullptr, ignored ? 1 : 0) == 0) _fail('SetConsoleCtrlHandler');
}

/// Operation-boundary seam: normalization must succeed before any spawn occurs.
T enableWindowsCtrlCBeforeSpawn<T>(
  T Function() spawn, {
  void Function(bool)? setIgnored,
}) {
  (setIgnored ?? setWindowsCtrlCIgnored)(false);
  return spawn();
}

WindowsSuspendedProcess startWindowsInterruptible(
  WindowsJob job,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  WindowsProcessPipes? output,
}) => enableWindowsCtrlCBeforeSpawn(
  () => job.spawn(
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    output: output,
    newConsole: true,
  ),
);

/// Native witness; an empty list means this process has no console.
List<int> windowsConsoleMembers() {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  var capacity = 16;
  while (true) {
    final buffer = calloc<Uint32>(capacity);
    try {
      final count = _members!(buffer, capacity);
      if (count == 0) {
        final error = _error();
        if (error == 6) return []; // ERROR_INVALID_HANDLE: no console.
        throw OSError('GetConsoleProcessList', error);
      }
      if (count <= capacity) return buffer.asTypedList(count).toList()..sort();
      capacity = count;
    } finally {
      calloc.free(buffer);
    }
  }
}

/// Called only by the standalone sender, never by the harness.
Future<void> sendWindowsCtrlC(int target) async {
  if (!Platform.isWindows) throw UnsupportedError('Native Windows required');
  if (target <= 0 || target >= 0xffffffff)
    throw ArgumentError.value(target, 'target');
  _free!(); // An initially console-less sender is valid.
  if (_attach!(target) == 0) _fail('AttachConsole');
  var failed = false;
  try {
    // AttachConsole resets the handler table; ignore must be installed after it.
    setWindowsCtrlCIgnored(true);
    stdout.writeln(
      jsonEncode({'sender': pid, 'members': windowsConsoleMembers()}),
    );
    await stdout.flush();
    if (_generate!(0, 0) == 0)
      _fail('GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    finishWindowsConsoleCleanup([
      () {
        if (_free!() == 0) _fail('FreeConsole');
      },
    ], operationFailed: failed);
  }
}

/// Own a short-lived sender tree, capture diagnostics, and bound its execution.
/// [senderCommand] is the exact pinned Dart entrypoint or prepared AOT sender.
Future<String> runWindowsConsoleSender(List<String> senderCommand) async {
  WindowsJob? job;
  WindowsSuspendedProcess? process;
  WindowsProcessPipes? pipes;
  var failed = false;
  try {
    pipes = WindowsProcessPipes();
    job = WindowsJob();
    process = job.spawn(senderCommand, output: pipes);
    final result = await pipes.communicate(
      () => process!.exitCode,
      const Duration(seconds: 5),
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Windows CTRL_C sender exited ${result.exitCode}: ${utf8.decode(result.stderr, allowMalformed: true)}',
      );
    }
    return utf8.decode(result.stdout);
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    finishWindowsConsoleCleanup([
      () => job?.close(),
      () => process?.close(),
      () => pipes?.close(),
    ], operationFailed: failed);
  }
}

/// Narrow cleanup seam shared only by console attachment and sender ownership.
/// Keep an in-flight operation error; otherwise surface the first release error.
void finishWindowsConsoleCleanup(
  List<void Function()> releases, {
  required bool operationFailed,
}) {
  Object? first;
  StackTrace? trace;
  for (final release in releases) {
    try {
      release();
    } catch (error, stack) {
      first ??= error;
      trace ??= stack;
    }
  }
  if (!operationFailed && first != null) {
    Error.throwWithStackTrace(first, trace!);
  }
}
