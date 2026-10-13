// Copies a trusted installation into an owned process-fault fixture.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

File stageInstallation(File executable, Directory destination) {
  executable = File(executable.resolveSymbolicLinksSync());
  final source = executable.parent.parent.parent;
  final relative = p.relative(executable.path, from: source.path);
  final layouts = [
    p.join('bin', 'linux-x64', 'archway'),
    p.join('bin', 'macos-arm64', 'archway'),
    p.join('bin', 'macos-universal', 'archway'),
    p.join('bin', 'windows-x64', 'archway.exe'),
  ];
  if (!layouts.contains(relative)) {
    throw ArgumentError('Unrecognized native installation layout: $relative');
  }
  final binary = File(p.join(destination.path, relative));
  _createFresh(binary.parent, recursive: true);
  executable.copySync(binary.path);
  _copyMode(executable, binary.path);
  for (final name in ['native', 'assets']) {
    _copyTree(
      Directory(p.join(source.path, name)),
      Directory(p.join(destination.path, name)),
    );
  }
  return binary;
}

void _copyTree(Directory source, Directory destination) {
  _createFresh(destination);
  for (final entity in source.listSync(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      _copyTree(entity, Directory(target));
    } else if (entity is Link) {
      // CPython's symlinks=True copytree recurses junctions, unlike symlinks.
      if (Platform.isWindows) {
        final link = _readWindowsLink(entity.path);
        if (link.tag == 0xa0000003) {
          _copyTree(Directory(entity.path), Directory(target));
        } else {
          _createWindowsLink(target, link.target!);
        }
      } else {
        Link(target).createSync(entity.targetSync());
      }
    } else {
      File(entity.path).copySync(target);
      _copyMode(entity, target);
    }
  }
  _copyMode(source, destination.path);
}

void _createFresh(Directory directory, {bool recursive = false}) {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Fixture directory already exists',
      directory.path,
    );
  }
  directory.createSync(recursive: recursive);
}

({int tag, String? target}) _readWindowsLink(String path) {
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
    if (tag == 0xa0000003) return (tag: tag, target: null);
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
    var target = String.fromCharCodes([
      for (var i = 0; i < length; i += 2)
        data.getUint16(20 + offset + i, Endian.little),
    ]);
    // os.readlink keeps an extended prefix; Dart's Link.target strips it.
    if (target.length > 4 && target.startsWith('\\??\\')) {
      target = '\\\\?\\${target.substring(4)}';
    }
    return (tag: tag, target: target);
  });
}

void _createWindowsLink(String destination, String target) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final attributes = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Int32, Pointer<Uint32>),
        int Function(Pointer<Utf16>, int, Pointer<Uint32>)
      >('GetFileAttributesExW');
  final create = kernel
      .lookupFunction<
        Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('CreateSymbolicLinkW');
  using((arena) {
    final name = destination.toNativeUtf16(allocator: arena);
    final value = target.toNativeUtf16(allocator: arena);
    final absolute =
        target.startsWith('\\') ||
        target.startsWith('/') ||
        target.length > 1 && target[1] == ':';
    final resolved = absolute ? target : '${p.dirname(destination)}\\$target';
    var flags = 2; // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE.
    // Match CPython's destination-relative MAX_PATH directory inference.
    // Missing targets remain file links, regardless of the source link's type.
    if (destination.length < 260 && resolved.length < 260) {
      // WIN32_FILE_ATTRIBUTE_DATA is 36 bytes, starting with attributes.
      final information = arena<Uint32>(9);
      final found = attributes(
        resolved.toNativeUtf16(allocator: arena),
        0,
        information,
      );
      if (found != 0 && information.value & 0x10 != 0) flags |= 1;
    }
    var result = create(name, value, flags);
    var error = result == 0 ? lastError() : 0;
    if (result == 0 && error == 87) {
      result = create(name, value, flags & ~2);
      error = result == 0 ? lastError() : 0;
    }
    if (result == 0) {
      throw FileSystemException(
        'Create fixture symbolic link',
        destination,
        OSError('Win32', error),
      );
    }
  });
}

void _copyMode(FileSystemEntity source, String destination) {
  if (Platform.isWindows) return;
  final libc = DynamicLibrary.process();
  final chmod = Platform.isMacOS
      ? libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint16),
          int Function(Pointer<Utf8>, int)
        >('chmod')
      : libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)
        >('chmod');
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
      );
  final path = destination.toNativeUtf8();
  try {
    if (chmod(path, source.statSync().mode & 0xfff) != 0) {
      throw FileSystemException(
        'chmod copied fixture',
        destination,
        OSError('POSIX', errno().value),
      );
    }
  } finally {
    malloc.free(path);
  }
}
