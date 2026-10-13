// Windows acceptance fixture-tree ownership, never a product process supervisor.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'windows_process.dart';

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

final _create = _kernel
    ?.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
    >('CreateJobObjectW');
final _configure = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int, Pointer<Void>, int)
    >('SetInformationJobObject');
final _assign = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('AssignProcessToJobObject');
final _terminate = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('TerminateJobObject');
final _query = _kernel
    ?.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Int32,
        Pointer<Void>,
        Uint32,
        Pointer<Uint32>,
      ),
      int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
    >('QueryInformationJobObject');
final _close = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('CloseHandle');
Never _fail(String operation) => throw OSError(operation, _error());

final class WindowsJob {
  /// Optional operation replacements exercise only assignment/resume failures.
  WindowsJob({
    void Function(WindowsSuspendedProcess)? assignProcess,
    void Function(WindowsSuspendedProcess)? resumeProcess,
  }) : _assignProcess = assignProcess,
       _resumeProcess = resumeProcess {
    if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
      throw UnsupportedError('Windows Job Object requires native Windows x64');
    }
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION x64: size144, BasicLimit.Flags16.
    final limits = calloc<Uint8>(144);
    try {
      final handle = _create!(nullptr, nullptr);
      if (handle == nullptr) _fail('CreateJobObjectW');
      _handle = handle;
      (limits + 16).cast<Uint32>().value =
          0x2000; // KILL_ON_JOB_CLOSE, no breakaway.
      if (_configure!(handle, 9, limits.cast(), 144) == 0) {
        final error = OSError('SetInformationJobObject', _error());
        _handle = null;
        if (_close!(handle) == 0) _fail('CloseHandle');
        throw error;
      }
    } finally {
      calloc.free(limits);
    }
  }

  final void Function(WindowsSuspendedProcess)? _assignProcess;
  final void Function(WindowsSuspendedProcess)? _resumeProcess;
  Pointer<Void>? _handle;
  bool get isClosed => _handle == null;

  /// Borrowed for independent native observations; this owner alone closes it.
  Pointer<Void> get nativeHandle =>
      _handle ?? (throw StateError('Job is closed'));

  WindowsSuspendedProcess spawn(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    final handle = _handle ?? (throw StateError('Job is closed'));
    WindowsSuspendedProcess? process;
    try {
      process = WindowsSuspendedProcess.start(
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      if (_assignProcess case final replacement?) {
        replacement(process);
      } else if (_assign!(handle, process.nativeHandle) == 0) {
        _fail('AssignProcessToJobObject');
      }
      // The process remains suspended until it belongs to this job.
      if (_resumeProcess case final replacement?) {
        replacement(process);
      } else {
        process.resume();
      }
      return process;
    } catch (_) {
      try {
        process?.close(); // Kill/reap even when assignment never succeeded.
      } finally {
        close();
      }
      rethrow;
    }
  }

  int get activeProcessCount {
    final handle = _handle ?? (throw StateError('Job is closed'));
    // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION: size48, ActiveProcesses40.
    final information = calloc<Uint8>(48);
    try {
      if (_query!(handle, 1, information.cast(), 48, nullptr) == 0) {
        _fail('QueryInformationJobObject');
      }
      return (information + 40).cast<Uint32>().value;
    } finally {
      calloc.free(information);
    }
  }

  void close() {
    final handle = _handle;
    if (handle == null) return;
    try {
      if (_terminate!(handle, 1) == 0) _fail('TerminateJobObject');
      final elapsed = Stopwatch()..start();
      while (activeProcessCount != 0) {
        if (elapsed.elapsed >= const Duration(seconds: 5)) {
          throw StateError('Owned Windows job cleanup unconfirmed');
        }
        sleep(const Duration(milliseconds: 10));
      }
    } finally {
      _handle = null; // Consume ownership even when close reports an error.
      if (_close!(handle) == 0) _fail('CloseHandle');
    }
  }
}
