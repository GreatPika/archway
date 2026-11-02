// Fixture-only raw UTF-16 symlink creation and readback.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Dart/Node UTF-8 path conversions cannot carry an unpaired native UTF-16 unit.
// These fixture-only Win32 calls preserve and verify the Python surrogateescape
// case without changing the target or weakening the malformed-encoding probe.
void createWindowsRawLink(
  String path,
  String target, {
  bool directory = false,
}) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final create = kernel
      .lookupFunction<
        Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('CreateSymbolicLinkW');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  using((arena) {
    final name = path.toNativeUtf16(allocator: arena);
    final value = target.toNativeUtf16(allocator: arena);
    var result = create(name, value, 2 | (directory ? 1 : 0));
    var code = result == 0 ? error() : 0;
    if (result == 0 && code == 87) {
      result = create(name, value, directory ? 1 : 0);
      code = result == 0 ? error() : 0;
    }
    if (result == 0) {
      throw FileSystemException(
        'Create raw Windows alias',
        path,
        OSError('Win32', code),
      );
    }
  });
}

String readWindowsRawLink(String path) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  // Resolve every function before a fallible call can set thread last-error.
  final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final open = kernel
      .lookupFunction<
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
  final query = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Void>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('DeviceIoControl');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  return using((arena) {
    final nativePath = path.toNativeUtf16(allocator: arena);
    final bytes = arena<Uint8>(16384); // MAXIMUM_REPARSE_DATA_BUFFER_SIZE.
    final count = arena<Uint32>();
    // OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT; no target follow.
    final handle = open(nativePath, 0, 7, nullptr, 3, 0x02200000, nullptr);
    if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
      final code = lastError();
      throw FileSystemException(
        'Open fixture reparse point',
        path,
        OSError('Win32', code),
      );
    }
    OSError? failure;
    var operation = 'Read fixture reparse point';
    try {
      // FSCTL_GET_REPARSE_POINT; no reparse data is ever written by this copier.
      if (query(handle, 0x900a8, nullptr, 0, bytes, 16384, count, nullptr) ==
          0) {
        failure = OSError('Win32', lastError());
      }
    } finally {
      // Consume this handle once, and retain a primary query error if present.
      if (close(handle) == 0) {
        final code = lastError();
        if (failure == null) {
          operation = 'Close fixture reparse point';
          failure = OSError('Win32', code);
        }
      }
    }
    if (failure != null) throw FileSystemException(operation, path, failure);
    if (count.value < 8 || count.value > 16384) {
      throw FileSystemException('Invalid reparse buffer size', path);
    }
    final data = ByteData.sublistView(bytes.asTypedList(count.value));
    final tag = data.getUint32(0, Endian.little);
    final end = 8 + data.getUint16(4, Endian.little);
    if (tag != 0xa000000c || end < 20 || end > data.lengthInBytes) {
      throw FileSystemException('Invalid symbolic-link reparse data', path);
    }
    // SymbolicLinkReparseBuffer.PathBuffer starts at byte 20. Offsets are bytes.
    final offset = data.getUint16(8, Endian.little);
    final length = data.getUint16(10, Endian.little);
    if (offset.isOdd || length.isOdd || 20 + offset + length > end) {
      throw FileSystemException('Invalid substitute-name extent', path);
    }
    return String.fromCharCodes([
      for (var i = 0; i < length; i += 2)
        data.getUint16(20 + offset + i, Endian.little),
    ]);
  });
}
