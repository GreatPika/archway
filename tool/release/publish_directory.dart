// Developer-only no-clobber publication of a prepared local directory.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Success transfers [stage] to [destination]. On failure the caller retains
/// [stage] and [destination] remains unchanged.
/// Files must be closed. This does not verify contents or promise crash durability.
void publishDirectory(Directory stage, Directory destination) {
  final source = stage.absolute.path, target = destination.absolute.path;
  for (final path in [source, target]) {
    if (path.contains('\x00') || utf8.decode(utf8.encode(path)) != path) {
      throw const FormatException('Unrepresentable publication path');
    }
  }
  if (source == target ||
      FileSystemEntity.typeSync(source, followLinks: false) !=
          FileSystemEntityType.directory ||
      stage.resolveSymbolicLinksSync() != source ||
      stage.parent.absolute.path != destination.parent.absolute.path ||
      destination.parent.resolveSymbolicLinksSync() !=
          destination.parent.absolute.path) {
    throw const FormatException('Expected canonical sibling staging directory');
  }
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final move = kernel
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    using((arena) {
      final from = _windowsPath(source).toNativeUtf16(allocator: arena);
      final to = _windowsPath(target).toNativeUtf16(allocator: arena);
      if (move(from, to, 0) == 0) {
        final code = error();
        throw FileSystemException(
          'Directory publication failed',
          target,
          OSError('Win32', code),
        );
      }
    });
  } else if (Platform.isLinux || Platform.isMacOS) {
    final libc = DynamicLibrary.process();
    final error = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          Platform.isMacOS ? '__error' : '__errno_location',
        );
    final int Function(Pointer<Utf8>, Pointer<Utf8>) move;
    if (Platform.isLinux) {
      final rename = libc
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
            int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
          >('renameat2');
      move = (from, to) => rename(-100, from, -100, to, 1); // RENAME_NOREPLACE
    } else {
      final rename = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('renamex_np');
      move = (from, to) => rename(from, to, 4); // RENAME_EXCL
    }
    using((arena) {
      final from = source.toNativeUtf8(allocator: arena);
      final to = target.toNativeUtf8(allocator: arena);
      if (move(from, to) != 0) {
        final code = error().value;
        throw FileSystemException(
          'Directory publication failed',
          target,
          OSError('POSIX', code),
        );
      }
    });
  } else {
    throw UnsupportedError('Native directory publication is unavailable');
  }
}

// Use extended-length paths without changing ordinary Win32 component semantics.
String _windowsPath(String value) {
  final path = value.replaceAll('/', r'\');
  final root = p.windows.rootPrefix(path);
  final drive = RegExp(r'^[A-Za-z]:\\$').hasMatch(root);
  final unc = RegExp(r'^\\\\[^\\?\.][^\\]*\\[^\\]+\\?$').hasMatch(root);
  if ((!drive && !unc) ||
      path
          .substring(root.length)
          .split(r'\')
          .any(
            (part) =>
                part.isEmpty ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                part.contains(':') ||
                RegExp(
                  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          )) {
    throw const FormatException('Unsupported Windows publication path');
  }
  return drive ? '\\\\?\\$path' : '\\\\?\\UNC\\${path.substring(2)}';
}
