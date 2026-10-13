// Developer-only anonymous output pipes and their restricted startup handle list.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

late final int Function() _error;
final _api = _loadApi();
DynamicLibrary? _loadApi() {
  if (!Platform.isWindows) return null;
  final api = DynamicLibrary.open('kernel32.dll');
  _error = api.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
    isLeaf: true,
  );
  // Initialize the error reader's cold FFI call path before a fallible call.
  // Leaf calls avoid non-leaf VM transitions; separate calls are not atomic.
  _error();
  return api;
}

final _pipe = _api
    ?.lookupFunction<
      Int32 Function(
        Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>,
        Pointer<Void>,
        Uint32,
      ),
      int Function(
        Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>,
        Pointer<Void>,
        int,
      )
    >('CreatePipe');
final _inherit = _api
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Uint32),
      int Function(Pointer<Void>, int, int)
    >('SetHandleInformation');
final _close = _api
    ?.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('CloseHandle');
final _init = _api
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<UintPtr>),
      int Function(Pointer<Void>, int, int, Pointer<UintPtr>)
    >('InitializeProcThreadAttributeList', isLeaf: true);
final _update = _api
    ?.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        UintPtr,
        Pointer<Void>,
        UintPtr,
        Pointer<Void>,
        Pointer<UintPtr>,
      ),
      int Function(
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
        int,
        Pointer<Void>,
        Pointer<UintPtr>,
      )
    >('UpdateProcThreadAttribute');
final _delete = _api
    ?.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)
    >('DeleteProcThreadAttributeList');
final _peek = _api
    ?.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Void>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Void>,
        int,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint32>,
      )
    >('PeekNamedPipe');
final _read = _api
    ?.lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Uint8>,
        int,
        Pointer<Uint32>,
        Pointer<Void>,
      )
    >('ReadFile');
final _open = _api
    ?.lookupFunction<
      Pointer<Void> Function(
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        Pointer<Void>,
      ),
      Pointer<Void> Function(
        Pointer<Utf16>,
        int,
        int,
        Pointer<Void>,
        int,
        int,
        Pointer<Void>,
      )
    >('CreateFileW');
final _type = _api
    ?.lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('GetFileType');
final _information = _api
    ?.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Uint8>),
      int Function(Pointer<Void>, Pointer<Uint8>)
    >('GetFileInformationByHandle');
Never _fail(String operation) => throw OSError(operation, _error());

final class WindowsPipeTimeout extends TimeoutException {
  WindowsPipeTimeout(Duration timeout, this.stdout, this.stderr)
    : super('Native process/pipe completion unconfirmed', timeout);
  final Uint8List stdout;
  final Uint8List stderr;
}

final class WindowsProcessPipes {
  WindowsProcessPipes({
    this.onStdout,
    this.onStderr,
    this.retainOutput = true,
    File? stdinFile,
  }) {
    if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
      throw UnsupportedError('Native Windows x64 pipes required');
    }
    final security = calloc<Uint8>(24); // SECURITY_ATTRIBUTES x64.
    final pair = calloc<Pointer<Void>>(2);
    try {
      security.cast<Uint32>().value = 24;
      (security + 16).cast<Int32>().value = 1; // Inheritable child ends.
      if (stdinFile != null) _openStdin(stdinFile, security.cast());
      for (var index = stdinFile == null ? 0 : 1; index < 3; index++) {
        if (_pipe!(pair, pair + 1, security.cast(), 0) == 0)
          _fail('CreatePipe');
        _handles.addAll([pair[0], pair[1]]);
        if (index != 0 && _inherit!(pair[0], 1, 0) == 0)
          _fail('SetHandleInformation');
      }
      _consume(1); // Null input remains immediate EOF; files need no writer.
    } catch (_) {
      close();
      rethrow;
    } finally {
      calloc.free(pair);
      calloc.free(security);
    }
  }
  final void Function(List<int>)? onStdout, onStderr;
  final bool retainOutput;
  final _handles = <Pointer<Void>?>[]; // stdin pair, stdout pair, stderr pair.
  final _buffers = [BytesBuilder(copy: false), BytesBuilder(copy: false)];
  Pointer<Void> _attributes = nullptr;
  Pointer<Pointer<Void>> _allowed = nullptr;
  bool _initialized = false, _capturing = false, _closed = false;

  void _openStdin(File file, Pointer<Void> security) {
    if (!p.windows.isAbsolute(file.path) ||
        !p.windows.equals(file.path, file.resolveSymbolicLinksSync())) {
      throw ArgumentError('Windows stdin requires a canonical ordinary file');
    }
    final path = file.path.toNativeUtf16();
    final information = calloc<Uint8>(52); // BY_HANDLE_FILE_INFORMATION.
    try {
      final handle = _open!(
        path,
        0x80000000,
        1,
        security,
        3,
        0x00200080,
        nullptr,
      ); // READ, share READ, OPEN_EXISTING, OPEN_REPARSE_POINT.
      if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
        _fail('CreateFileW stdin');
      }
      _handles.addAll([
        handle,
        null,
      ]); // Ownership precedes fallible validation.
      if (_type!(handle) != 1)
        throw ArgumentError('Windows stdin must be disk-backed');
      if (_information!(handle, information) == 0)
        _fail('GetFileInformationByHandle stdin');
      if (information.cast<Uint32>().value & 0x410 != 0) {
        throw ArgumentError(
          'Windows stdin must not be a directory or reparse point',
        );
      }
    } finally {
      calloc.free(information);
      malloc.free(path);
    }
  }

  void prepareStartup(Pointer<Uint8> startup) {
    if (_closed || _attributes != nullptr || _handles[0] == null) {
      throw StateError('Pipe startup already consumed');
    }
    final size = calloc<UintPtr>();
    try {
      final result = _init!(nullptr, 1, 0, size);
      final error = _error();
      if (result != 0 || error != 122)
        throw OSError('Attribute-list size', error);
      _attributes = calloc<Uint8>(size.value).cast();
      if (_init!(_attributes, 1, 0, size) == 0)
        _fail('InitializeProcThreadAttributeList');
      _initialized = true;
      _allowed = calloc<Pointer<Void>>(3);
      for (var index = 0; index < 3; index++) {
        _allowed[index] = _handles[[0, 3, 5][index]]!;
      }
      if (_update!(
            _attributes,
            0,
            0x20002,
            _allowed.cast(),
            24,
            nullptr,
            nullptr,
          ) ==
          0) {
        _fail('UpdateProcThreadAttribute HANDLE_LIST');
      }
      startup.cast<Uint32>().value = 112; // STARTUPINFOEXW x64.
      (startup + 60).cast<Uint32>().value =
          0x101; // USESTDHANDLES | USESHOWWINDOW.
      for (var index = 0; index < 3; index++) {
        (startup + 80 + index * 8).cast<Pointer<Void>>().value =
            _allowed[index];
      }
      (startup + 104).cast<Pointer<Void>>().value = _attributes;
    } finally {
      calloc.free(size);
    }
  }

  void finishSpawn() {
    if (_initialized) _delete!(_attributes);
    _initialized = false;
    if (_attributes != nullptr) calloc.free(_attributes);
    _attributes = nullptr;
    if (_allowed != nullptr) calloc.free(_allowed);
    _allowed = nullptr;
    Object? failure;
    for (final index in [0, 3, 5]) {
      try {
        _consume(index);
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  void _consume(int index) {
    if (index >= _handles.length) return;
    final handle = _handles[index];
    _handles[index] = null;
    if (handle != null && _close!(handle) == 0) _fail('CloseHandle pipe');
  }

  void _drain(int stream, Pointer<Uint8> bytes, Pointer<Uint32> count) {
    final index = 2 + stream * 2;
    final handle = _handles[index];
    if (handle == null) return;
    if (_peek!(handle, nullptr, 0, nullptr, count, nullptr) == 0) {
      final error = _error();
      if (error == 109) {
        _consume(index);
        return;
      } // ERROR_BROKEN_PIPE is EOF.
      throw OSError('PeekNamedPipe', error);
    }
    if (count.value == 0) return;
    final amount = count.value > 65536 ? 65536 : count.value;
    if (_read!(handle, bytes, amount, count, nullptr) == 0)
      _fail('ReadFile pipe');
    final chunk = Uint8List.fromList(bytes.asTypedList(count.value));
    (stream == 0 ? onStdout : onStderr)?.call(chunk);
    if (retainOutput) _buffers[stream].add(chunk);
  }

  Future<({int exitCode, Uint8List stdout, Uint8List stderr})> communicate(
    int? Function() exitCode,
    Duration timeout,
  ) async {
    if (_closed || _capturing) throw StateError('Capture unavailable');
    _capturing = true;
    final bytes = calloc<Uint8>(65536), count = calloc<Uint32>();
    final elapsed = Stopwatch()..start();
    try {
      while (true) {
        _drain(0, bytes, count);
        _drain(1, bytes, count);
        final code = exitCode();
        if (code != null && _handles[2] == null && _handles[4] == null) {
          return (
            exitCode: code,
            stdout: _buffers[0].toBytes(),
            stderr: _buffers[1].toBytes(),
          );
        }
        if (elapsed.elapsed >= timeout) {
          throw WindowsPipeTimeout(
            timeout,
            _buffers[0].toBytes(),
            _buffers[1].toBytes(),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    } finally {
      calloc.free(count);
      calloc.free(bytes);
      _capturing = false;
    }
  }

  void close() {
    if (_closed) return;
    if (_capturing) throw StateError('Cannot close during active capture');
    _closed = true;
    try {
      finishSpawn();
    } finally {
      Object? failure;
      for (final index in [1, 2, 4]) {
        try {
          _consume(index);
        } catch (error) {
          failure ??= error;
        }
      }
      if (failure != null) throw failure;
    }
  }
}
