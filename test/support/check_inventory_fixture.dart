// Independent fixture inventory. Never calls Archway's inventory classifier.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'native_process_support.dart';

String _extended(String path) => path.startsWith(r'\\?\')
    ? path
    : path.startsWith(r'\\')
    ? '\\\\?\\UNC\\${path.substring(2)}'
    : '\\\\?\\$path';

Future<List<dynamic>> inventoryEntries(String folder, String node) async {
  if (Platform.isWindows) return _windowsEntries(folder);
  final result = await runNativeProcess([
    node,
    '-e',
    r'''
const fs=require('node:fs');
const entries=fs.readdirSync(process.argv[1],{withFileTypes:true}).map(e=>[
 e.name,e.isSymbolicLink()?'symlink':e.isFile()?'file':e.isDirectory()?'directory':'other']);
process.stdout.write(JSON.stringify(entries));
''',
    folder,
  ], timeout: const Duration(seconds: 15));
  if (result.exitCode != 0 || result.stderr.isNotEmpty)
    throw StateError('Inventory producer failed: $result');
  return _sorted(jsonDecode(utf8.decode(result.stdout)) as List);
}

List<dynamic> _sorted(List<dynamic> entries) => entries
  ..sort((a, b) {
    // Python sorts Unicode scalar values, rather than UTF-16 code units.
    final left = (a[0] as String).runes.toList(),
        right = (b[0] as String).runes.toList();
    for (var i = 0; i < left.length && i < right.length; i++) {
      if (left[i] != right[i]) return left[i].compareTo(right[i]);
    }
    return left.length.compareTo(right.length);
  });

List<dynamic> _windowsEntries(String folder) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final first = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Uint8>)
      >('FindFirstFileW');
  final next = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>),
        int Function(Pointer<Void>, Pointer<Uint8>)
      >('FindNextFileW');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FindClose');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  return using((arena) {
    // WIN32_FIND_DATAW: attributes at 0, reparse tag at 36, name at 44.
    final data = arena<Uint8>(592);
    final handle = first(
      _extended(p.join(folder, '*')).toNativeUtf16(allocator: arena),
      data,
    );
    if (handle.address == -1 || handle.address == 0xffffffffffffffff)
      throw OSError('FindFirstFileW', error());
    final entries = <dynamic>[];
    try {
      while (true) {
        final bytes = ByteData.sublistView(data.asTypedList(592));
        final name = (data + 44).cast<Utf16>().toDartString();
        final attributes = bytes.getUint32(0, Endian.little),
            tag = bytes.getUint32(36, Endian.little);
        if (name != '.' && name != '..')
          entries.add([
            name,
            attributes & 0x400 != 0
                ? (tag == 0x80000023 ? 'other' : 'symlink')
                : attributes & 0x10 != 0
                ? 'directory'
                : 'file',
          ]);
        if (next(handle, data) == 0) {
          final code = error();
          if (code != 18) throw OSError('FindNextFileW', code);
          break;
        }
      }
    } finally {
      if (close(handle) == 0) throw OSError('FindClose', error());
    }
    return _sorted(entries);
  });
}

List<dynamic> windowsInventoryAttributes(String folder, List<dynamic> entries) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final attributes = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Int32, Pointer<Uint32>),
        int Function(Pointer<Utf16>, int, Pointer<Uint32>)
      >('GetFileAttributesExW');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  return using(
    (arena) => [
      for (final entry in entries)
        (() {
          final data = arena<Uint32>(9);
          final succeeded =
              attributes(
                _extended(p.join(folder, entry[0] as String))
                    .toNativeUtf16(allocator: arena),
                0,
                data,
              ) !=
              0;
          final code = succeeded ? null : error();
          return {
            'name': entry[0],
            'listed_kind': entry[1],
            'attributes': succeeded ? data.value : null,
            'win32_error': code,
          };
        })(),
    ],
  );
}

({int attributes, int tag}) windowsReparseMetadata(String path) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final first = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Uint8>)
      >('FindFirstFileW');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FindClose');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  return using((arena) {
    final data = arena<Uint8>(592);
    final handle = first(_extended(path).toNativeUtf16(allocator: arena), data);
    if (handle.address == -1 || handle.address == 0xffffffffffffffff)
      throw OSError('FindFirstFileW', error());
    try {
      final bytes = ByteData.sublistView(data.asTypedList(592));
      return (
        attributes: bytes.getUint32(0, Endian.little),
        tag: bytes.getUint32(36, Endian.little),
      );
    } finally {
      if (close(handle) == 0) throw OSError('FindClose', error());
    }
  });
}

// Junction controls must pass an absolute native executable to the runner.
String windowsInventoryCommand() {
  final root = Platform.environment.entries
      .where((entry) => entry.key.toUpperCase() == 'SYSTEMROOT')
      .map((entry) => entry.value)
      .firstOrNull;
  if (root == null || !p.windows.isAbsolute(root)) {
    throw StateError('Absolute SystemRoot is required for junction fixtures');
  }
  final command = p.windows.join(root, 'System32', 'cmd.exe');
  if (!File(command).existsSync()) {
    throw StateError('System command interpreter is missing: $command');
  }
  return command;
}
