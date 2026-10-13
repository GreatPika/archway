// Developer-only native resources for filesystem acceptance tests.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _CreateFileNative = Pointer<Void> Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Void>,
);
typedef _CreateFile = Pointer<Void> Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
);

final _kernel = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
final _createFile = _kernel?.lookupFunction<_CreateFileNative, _CreateFile>(
  'CreateFileW',
);
final _closeHandle = _kernel
    ?.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('CloseHandle');
final _lastError = _kernel?.lookupFunction<Uint32 Function(), int Function()>(
  'GetLastError',
);

Never _windowsError(String operation, [int? code]) => throw FileSystemException(
  operation,
  '',
  OSError('Win32', code ?? _lastError!()),
);

void _close(Pointer<Void> handle) {
  if (_closeHandle!(handle) == 0) _windowsError('CloseHandle');
}

/// Owns an actual filename containing byte FF (POSIX) or code unit DCFF
/// (Windows). Never passes the malformed Windows path through UTF-8.
final class MalformedNativeFile {
  MalformedNativeFile(String parent, String name)
    : _path = '$parent${Platform.pathSeparator}$name\uDCFF',
      _bytes = Uint8List.fromList([
        ...utf8.encode('$parent${Platform.pathSeparator}$name'),
        0xff,
      ]);

  final String _path;
  final Uint8List _bytes;

  String get windowsPath => _path;
  Uint8List get posixPath => Uint8List.fromList(_bytes);

  void create([List<int> contents = const []]) {
    if (!Platform.isWindows) {
      File.fromRawPath(_bytes).createSync(exclusive: true);
      File.fromRawPath(_bytes).writeAsBytesSync(contents);
      return;
    }
    final path = _path.toNativeUtf16();
    try {
      final handle = _createFile!(
        path,
        0xC0000000,
        0,
        nullptr,
        1,
        0x80,
        nullptr,
      );
      if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
        _windowsError('CreateFileW malformed filename');
      }
      try {
        _transfer(handle, contents);
      } finally {
        _close(handle);
      }
    } finally {
      malloc.free(path);
    }
  }

  List<int> read() {
    if (!Platform.isWindows) return File.fromRawPath(_bytes).readAsBytesSync();
    final path = _path.toNativeUtf16();
    try {
      final handle = _createFile!(
        path,
        0x80000000,
        1,
        nullptr,
        3,
        0x80,
        nullptr,
      );
      if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
        _windowsError('CreateFileW fixture read');
      }
      try {
        return _transfer(handle, null);
      } finally {
        _close(handle);
      }
    } finally {
      malloc.free(path);
    }
  }

  List<int> _transfer(Pointer<Void> handle, List<int>? contents) {
    final operation = contents == null ? 'ReadFile' : 'WriteFile';
    final transfer = _kernel!
        .lookupFunction<
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
        >(operation);
    final capacity = contents?.length ?? 4096;
    final bytes = calloc<Uint8>(capacity + 1);
    final count = calloc<Uint32>();
    try {
      if (contents != null) bytes.asTypedList(capacity).setAll(0, contents);
      final result = <int>[];
      do {
        if (transfer(handle, bytes, capacity, count, nullptr) == 0) {
          _windowsError('$operation malformed filename');
        }
        if (contents != null) {
          if (count.value != capacity) throw StateError('Short fixture write');
          return contents;
        }
        result.addAll(bytes.asTypedList(count.value));
      } while (count.value != 0);
      return result;
    } finally {
      calloc.free(bytes);
      calloc.free(count);
    }
  }

  bool existsExactly() {
    if (!Platform.isWindows) return File.fromRawPath(_bytes).existsSync();
    final attributes = _kernel!
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('GetFileAttributesW');
    final path = _path.toNativeUtf16();
    try {
      if (attributes(path) != 0xffffffff) return true;
      final error = _lastError!();
      if (error == 2 || error == 3) return false;
      _windowsError('GetFileAttributesW malformed filename', error);
    } finally {
      malloc.free(path);
    }
  }

  void delete() {
    if (!Platform.isWindows) {
      File.fromRawPath(_bytes).deleteSync();
      return;
    }
    final delete = _kernel!
        .lookupFunction<
          Int32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('DeleteFileW');
    final path = _path.toNativeUtf16();
    try {
      if (delete(path) == 0) _windowsError('DeleteFileW malformed filename');
    } finally {
      malloc.free(path);
    }
  }
}

/// Creates the original platform-specific non-file resource at [path].
void createNonregularResource(String path) {
  if (Platform.isWindows) {
    final create = _kernel!
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Void>),
          int Function(Pointer<Utf16>, Pointer<Void>)
        >('CreateDirectoryW');
    final nativePath = path.toNativeUtf16();
    try {
      if (create(nativePath, nullptr) == 0)
        _windowsError('CreateDirectoryW nonregular resource');
    } finally {
      malloc.free(nativePath);
    }
    return;
  }
  final libc = DynamicLibrary.process();
  final mkfifo = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('mkfifo');
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
      );
  final nativePath = path.toNativeUtf8();
  try {
    if (mkfifo(nativePath, 0x1b6) != 0) {
      // Capture errno before freeing memory or performing another native call.
      final code = errno().value;
      throw FileSystemException('mkfifo', path, OSError('POSIX', code));
    }
  } finally {
    malloc.free(nativePath);
  }
}

void removeNonregularResource(String path) {
  if (Platform.isWindows) {
    Directory(path).deleteSync();
  } else {
    File(path).deleteSync();
  }
}

/// Holds CreateFileW's share-mode-zero denial until explicitly released.
final class ExclusiveWindowsFileLock {
  ExclusiveWindowsFileLock(String path) {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Win32 exclusive sharing fixture requires Windows',
      );
    }
    final nativePath = path.toNativeUtf16();
    try {
      final handle = _createFile!(
        nativePath,
        0xC0000000,
        0,
        nullptr,
        3,
        0x80,
        nullptr,
      );
      if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
        _windowsError('CreateFileW exclusive sharing lock');
      }
      _handle = handle;
    } finally {
      malloc.free(nativePath);
    }
  }

  Pointer<Void>? _handle;

  void close() {
    final handle = _handle;
    _handle = null; // Consume ownership even when CloseHandle reports an error.
    if (handle != null) _close(handle);
  }
}
