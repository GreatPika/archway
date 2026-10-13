// Developer-only native Windows process ownership; never a product launcher.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Microsoft C runtime argv quoting, with every argument quoted explicitly.
String windowsCommandLine(List<String> arguments) {
  if (arguments.isEmpty || arguments.any((value) => value.contains('\u0000'))) {
    throw ArgumentError('Expected nonempty argv without NUL');
  }
  return arguments
      .map((argument) {
        final result = StringBuffer('"');
        var slashes = 0;
        for (final unit in argument.codeUnits) {
          if (unit == 92) {
            slashes++;
            continue;
          }
          result.write('\\' * (unit == 34 ? slashes * 2 + 1 : slashes));
          result.writeCharCode(unit);
          slashes = 0;
        }
        result.write('\\' * (slashes * 2));
        result.write('"');
        return result.toString();
      })
      .join(' ');
}

final _kernel = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
final _error = _kernel?.lookupFunction<Uint32 Function(), int Function()>(
  'GetLastError',
);
final _close = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('CloseHandle');
final _wait = _kernel
    ?.lookupFunction<
      Uint32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('WaitForSingleObject');
final _terminate = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('TerminateProcess');
final _resume = _kernel
    ?.lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('ResumeThread');
final _exit = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Uint32>),
      int Function(Pointer<Void>, Pointer<Uint32>)
    >('GetExitCodeProcess');
final _create = _kernel
    ?.lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
        Int32,
        Uint32,
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Void>,
      )
    >('CreateProcessW');

Never _fail(String operation) => throw OSError(operation, _error!());
void _closeHandle(Pointer<Void> handle) {
  if (_close!(handle) == 0) _fail('CloseHandle');
}

/// Narrow termination/wait seam; callbacks operate on one retained handle.
int confirmWindowsProcessTermination({
  required OSError? Function() terminate,
  required int Function(int milliseconds) wait,
  required int Function() readExitCode,
}) {
  final failure = terminate();
  // ERROR_ACCESS_DENIED can mean the child exited after our running probe.
  // Only a signalled wait on that same handle establishes successful cleanup.
  final int state;
  try {
    state = wait(5000);
  } catch (_) {
    if (failure != null) throw failure;
    rethrow;
  }
  if (state != 0) {
    throw failure ?? StateError('Suspended fixture exit unconfirmed');
  }
  return readExitCode();
}

/// Owns exactly one native process and its initial suspended thread.
/// No handles are inherited. Pipe capture and job policy are separate controls.
final class WindowsSuspendedProcess {
  WindowsSuspendedProcess._(this.pid, this._process, this._thread);

  static WindowsSuspendedProcess start(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
      throw UnsupportedError('Suspended fixture requires native Windows x64');
    }
    final command = windowsCommandLine(arguments);
    if (!p.windows.isAbsolute(arguments.first) ||
        (workingDirectory != null &&
            (!p.windows.isAbsolute(workingDirectory) ||
                workingDirectory.contains('\u0000')))) {
      throw ArgumentError(
        'Fixture executable and working directory must be absolute',
      );
    }
    if (command.length >= 32767)
      throw ArgumentError('Windows command line too long');
    String? environmentBlock;
    if (environment != null) {
      final keys = environment.keys.toList()
        ..sort((a, b) => a.toUpperCase().compareTo(b.toUpperCase()));
      final seen = <String>{};
      for (final key in keys) {
        if (key.isEmpty ||
            key.contains('=') ||
            key.contains('\u0000') ||
            environment[key]!.contains('\u0000') ||
            !seen.add(key.toUpperCase())) {
          throw ArgumentError('Invalid or duplicate Windows environment key');
        }
      }
      environmentBlock =
          '${keys.map((key) => '$key=${environment[key]}').join('\u0000')}\u0000';
    }
    final application = arguments.first.toNativeUtf16();
    final commandLine = command
        .toNativeUtf16(); // CreateProcessW may mutate it.
    final directory = workingDirectory?.toNativeUtf16() ?? nullptr;
    final env = environmentBlock?.toNativeUtf16() ?? nullptr;
    // Native Windows x64 layouts: STARTUPINFOW104, PROCESS_INFORMATION24.
    final startup = calloc<Uint8>(104);
    final information = calloc<Uint8>(24);
    try {
      startup.cast<Uint32>().value = 104;
      (startup + 60).cast<Uint32>().value = 1; // STARTF_USESHOWWINDOW.
      // wShowWindow remains SW_HIDE=0. No STARTF_USESTDHANDLES yet.
      final flags =
          0x4 |
          (environment == null ? 0 : 0x400); // SUSPENDED | UNICODE_ENVIRONMENT.
      if (_create!(
            application,
            commandLine,
            nullptr,
            nullptr,
            0,
            flags,
            env.cast(),
            directory,
            startup.cast(),
            information.cast(),
          ) ==
          0) {
        _fail('CreateProcessW');
      }
      return WindowsSuspendedProcess._(
        (information + 16).cast<Uint32>().value,
        information.cast<Pointer<Void>>().value,
        (information + 8).cast<Pointer<Void>>().value,
      );
    } finally {
      calloc.free(information);
      calloc.free(startup);
      if (env != nullptr) malloc.free(env);
      if (directory != nullptr) malloc.free(directory);
      malloc.free(commandLine);
      malloc.free(application);
    }
  }

  final int pid;
  Pointer<Void>? _process;
  Pointer<Void>? _thread;
  int? _exitCode;

  /// Borrowed handle: the process owner alone closes it.
  Pointer<Void> get nativeHandle =>
      _process ?? (throw StateError('Process is closed'));

  int? get exitCode {
    final handle = _process;
    if (handle == null) return _exitCode;
    final state = _wait!(handle, 0);
    if (state == 258) return null;
    if (state == 0xffffffff) _fail('WaitForSingleObject');
    if (state != 0) throw StateError('Unexpected process wait: $state');
    final code = calloc<Uint32>();
    try {
      if (_exit!(handle, code) == 0) _fail('GetExitCodeProcess');
      return _exitCode = code.value;
    } finally {
      calloc.free(code);
    }
  }

  void resume() {
    final thread = _thread;
    if (thread == null) throw StateError('Initial thread is not owned');
    try {
      final count = _resume!(thread);
      if (count == 0xffffffff) _fail('ResumeThread');
      if (count != 1)
        throw StateError('Owned initial thread resume count was $count');
      _thread = null;
      _closeHandle(thread);
    } catch (error, stack) {
      // A failed resume must not leave a suspended or unexpectedly running child.
      close();
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Kill and confirm exit before consuming both handles, including on errors.
  void close() {
    final process = _process;
    if (process == null) return;
    try {
      if (exitCode == null) {
        _exitCode = confirmWindowsProcessTermination(
          terminate: () => _terminate!(process, 1) == 0
              ? OSError('TerminateProcess', _error!())
              : null,
          wait: (milliseconds) {
            final state = _wait!(process, milliseconds);
            if (state == 0xffffffff) _fail('WaitForSingleObject');
            return state;
          },
          readExitCode: () =>
              exitCode ??
              (throw StateError('Signalled process exit code unavailable')),
        );
      }
    } finally {
      _process = null;
      final thread = _thread;
      _thread = null;
      try {
        if (thread != null) _closeHandle(thread);
      } finally {
        _closeHandle(process);
      }
    }
  }
}
