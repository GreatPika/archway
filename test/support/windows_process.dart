// Developer-only native Windows process ownership; never a product launcher.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'windows_process_pipes.dart';
import 'windows_command.dart';

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

late final int Function() _error;
final _kernel = _loadKernel();

DynamicLibrary? _loadKernel() {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  // Resolve before any fallible call: symbol lookup can reset thread last-error.
  _error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
    isLeaf: true,
  );
  // Warm the leaf reader before a fallible call can set thread-local error.
  _error();
  return kernel;
}

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
DynamicLibrary? _processBridge() {
  if (!Platform.isWindows) return null;
  final library = File('build/windows-process/archway_process.dll').absolute;
  if (!library.existsSync()) {
    throw StateError(
      'Windows process test support is unprepared. From the repository root run '
      'dart --suppress-analytics run tool/ci/prepare_windows_process_support.dart',
    );
  }
  return DynamicLibrary.open(library.path);
}

final _create = _processBridge()
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
        Pointer<Uint32>,
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
        Pointer<Uint32>,
      )
    >('archway_create_process');

Never _fail(String operation) => throw OSError(operation, _error());
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
/// Optional output capture inherits only its restricted standard handles.
final class WindowsSuspendedProcess {
  WindowsSuspendedProcess._(this.pid, this._process, this._thread);

  static WindowsSuspendedProcess start(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    WindowsProcessPipes? output,
    bool newConsole = false,
    WindowsRawCommandLine? windowsCommand,
  }) {
    if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
      throw UnsupportedError('Suspended fixture requires native Windows x64');
    }
    if (arguments.isEmpty) throw ArgumentError('Expected nonempty argv');
    windowsCommand?.validateFor(arguments);
    final applicationName = windowsCommand?.applicationName ?? arguments.first;
    final command =
        windowsCommand?.commandLine ?? windowsCommandLine(arguments);
    if (!p.windows.isAbsolute(applicationName) ||
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
    final application = applicationName.toNativeUtf16();
    final commandLine = command
        .toNativeUtf16(); // CreateProcessW may mutate it.
    final directory = workingDirectory?.toNativeUtf16() ?? nullptr;
    final env = environmentBlock?.toNativeUtf16() ?? nullptr;
    // Native Windows x64 layouts: STARTUPINFOW104, PROCESS_INFORMATION24.
    final startup = calloc<Uint8>(output == null ? 104 : 112);
    final information = calloc<Uint8>(24);
    final spawnError = calloc<Uint32>();
    WindowsSuspendedProcess? process;
    try {
      startup.cast<Uint32>().value = 104;
      (startup + 60).cast<Uint32>().value = 1; // STARTF_USESHOWWINDOW.
      // wShowWindow remains SW_HIDE=0.
      output?.prepareStartup(startup);
      final flags =
          0x4 |
          (newConsole ? 0x10 : 0) | // CREATE_NEW_CONSOLE, not a process group.
          (output == null ? 0 : 0x80000) |
          (environment == null ? 0 : 0x400); // SUSPENDED | UNICODE_ENVIRONMENT.
      if (_create!(
            application,
            commandLine,
            nullptr,
            nullptr,
            output == null ? 0 : 1,
            flags,
            env.cast(),
            directory,
            startup.cast(),
            information.cast(),
            spawnError,
          ) ==
          0) {
        // The native wrapper captures LastError before returning through FFI.
        final error = spawnError.value;
        throw OSError('CreateProcessW', error);
      }
      process = WindowsSuspendedProcess._(
        (information + 16).cast<Uint32>().value,
        information.cast<Pointer<Void>>().value,
        (information + 8).cast<Pointer<Void>>().value,
      );
      output?.finishSpawn();
      return process;
    } catch (_) {
      try {
        process?.close();
      } finally {
        output?.close();
      }
      rethrow;
    } finally {
      calloc.free(spawnError);
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
              ? OSError('TerminateProcess', _error())
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
