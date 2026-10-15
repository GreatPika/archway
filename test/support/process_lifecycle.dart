// Native lifecycle controls for developer acceptance fixtures only.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

final _libc = Platform.isWindows ? null : DynamicLibrary.process();
final _errno = _libc
    ?.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS ? '__error' : '__errno_location',
    );
final _kill = _libc
    ?.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
    );
final _getsid = _libc?.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'getsid',
);

/// The bootstrap execs in place: callers retain the real command's PID/streams.
Future<Process> startPosixSession(
  List<String> command, {
  required String workingDirectory,
  required Map<String, String> environment,
}) async {
  if (Platform.isWindows) throw UnsupportedError('POSIX session required');
  final source = await Isolate.resolvePackageUri(
    Uri.parse('package:archway/src/installation_layout.dart'),
  );
  final packages = await Isolate.packageConfig;
  if (source == null || packages == null)
    throw StateError('Prepared Archway source package required');
  final bootstrap = source.resolve(
    '../../test/support/posix_session_exec.dart',
  );
  return Process.start(
    Platform.resolvedExecutable,
    [
      '--suppress-analytics',
      'run',
      '--packages=$packages',
      bootstrap.toFilePath(),
      ...command,
    ],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
  );
}

/// Only a live isolated session leader may establish group signal ownership.
void signalPosixSession(int leader, ProcessSignal signal) {
  _validatePid(leader);
  if (Platform.isWindows) throw UnsupportedError('POSIX session required');
  final errno = _errno!();
  final session = _getsid!(leader);
  if (session < 0 && errno.value == 3) return;
  if (session != leader) throw StateError('Fixture is not an isolated session');
  signalPosixGroup(leader, signal);
}

/// For a group whose isolated leader was already observed before it exited.
void signalPosixGroup(int leader, ProcessSignal signal) {
  _validatePid(leader);
  if (Platform.isWindows) throw UnsupportedError('POSIX group required');
  final errno = _errno!();
  if (_kill!(-leader, signal.signalNumber) == 0) return;
  final code = errno.value;
  if (code != 3) throw OSError('kill(owned group)', code);
}

late final int Function() _error;
final _kernel = _loadKernel();

DynamicLibrary? _loadKernel() {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  // Resolve before any fallible call: symbol lookup can reset thread last-error.
  _error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  return kernel;
}

final _open = _kernel
    ?.lookupFunction<
      Pointer<Void> Function(Uint32, Int32, Uint32),
      Pointer<Void> Function(int, int, int)
    >('OpenProcess');
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
final _close = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('CloseHandle');

void _validatePid(int pid) {
  // A fixture PID is never a POSIX process-group selector.
  final maximum = Platform.isWindows ? 0xffffffff : 0x7fffffff;
  if (pid <= 0 || pid > maximum) throw ArgumentError.value(pid, 'pid');
}

Pointer<Void>? _processHandle(int pid, int access) {
  final handle = _open!(access, 0, pid);
  if (handle != nullptr) return handle;
  final code = _error();
  if (code == 87) return null; // ERROR_INVALID_PARAMETER: no such PID.
  throw OSError('OpenProcess', code);
}

int _state(Pointer<Void> handle, int milliseconds) {
  final state = _wait!(handle, milliseconds);
  if (state == 0xffffffff) throw OSError('WaitForSingleObject', _error());
  if (state != 0 && state != 258)
    throw StateError('Unexpected process wait: $state');
  return state;
}

void _closeOwned(Pointer<Void> handle) {
  if (_close!(handle) == 0) throw OSError('CloseHandle', _error());
}

/// POSIX signal zero; Windows uses only SYNCHRONIZE, never a kill API.
bool isProcessAlive(int pid) {
  _validatePid(pid);
  if (!Platform.isWindows) {
    // Resolve and obtain this thread's errno before the fallible native call.
    // Lazy symbol lookup can overwrite the error reported by kill.
    final errno = _errno!();
    if (_kill!(pid, 0) == 0) return true;
    final code = errno.value;
    if (code == 3) return false; // ESRCH on supported Linux/macOS hosts.
    throw OSError('kill(pid, 0)', code);
  }
  final handle = _processHandle(pid, 0x00100000);
  if (handle == null) return false;
  try {
    return _state(handle, 0) == 258;
  } finally {
    _closeOwned(handle);
  }
}

/// Force fixture cleanup; Windows confirms exit on the same retained handle.
/// POSIX callers must reap their child using its Process.exitCode future.
void terminateProcessId(int pid) {
  _validatePid(pid);
  if (!Platform.isWindows) {
    final errno = _errno!();
    if (_kill!(pid, 9) == 0) return;
    final code = errno.value;
    if (code == 3) return;
    throw OSError('kill(pid, SIGKILL)', code);
  }
  final handle = _processHandle(pid, 0x00100001);
  if (handle == null) return;
  try {
    if (_state(handle, 0) == 258) {
      if (_terminate!(handle, 1) == 0)
        throw OSError('TerminateProcess', _error());
      if (_state(handle, 5000) != 0) {
        throw StateError('Fixture process $pid did not terminate');
      }
    }
  } finally {
    _closeOwned(handle);
  }
}

/// Retains identity from the helper-ready barrier through termination/cleanup.
final class WindowsOwnedProcess {
  WindowsOwnedProcess(int pid) {
    if (!Platform.isWindows) throw UnsupportedError('Windows handle required');
    _validatePid(pid);
    _handle = _processHandle(pid, 0x00100001);
    if (_handle == null) throw StateError('Fixture process $pid already gone');
  }

  Pointer<Void>? _handle;
  bool get exited => _state(_handle!, 0) == 0;

  void terminate(int code) {
    final handle = _handle ?? (throw StateError('Fixture handle closed'));
    final failure = _terminate!(handle, code) == 0
        ? OSError('TerminateProcess', _error())
        : null;
    if (_state(handle, 3000) != 0)
      throw failure ?? StateError('Owned Windows fixture cleanup unconfirmed');
  }

  void close() {
    final handle = _handle;
    if (handle == null) return;
    try {
      if (!exited) terminate(1);
    } finally {
      _handle = null;
      _closeOwned(handle);
    }
  }
}
