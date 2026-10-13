// Only for the committed offline npm/pnpm snapshots, not release archives.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:tar/tar.dart';

String _archivePath(String value) {
  final normalized = p.posix.normalize(value);
  if (p.posix.isAbsolute(value) ||
      value.contains(r'\') ||
      value.contains(':') ||
      normalized == '..' ||
      normalized.startsWith('../')) {
    throw FormatException('Non-relative fixture archive path: $value');
  }
  return normalized;
}

Future<void> extractNodeFixture(File archive, Directory destination) async {
  if (FileSystemEntity.isLinkSync(destination.path)) {
    throw const FormatException(
      'Fixture destination must be an ordinary directory',
    );
  }
  final reader = TarReader(archive.openRead().transform(gzip.decoder));
  final members = <String, ({TarHeader header, List<int> bytes})>{};
  try {
    while (await reader.moveNext()) {
      final header = reader.current.header;
      final name = _archivePath(header.name);
      if (header.name.split('/').contains('..') || members.containsKey(name)) {
        throw FormatException('Ambiguous archive member: ${header.name}');
      }
      if (![
        TypeFlag.reg,
        TypeFlag.dir,
        TypeFlag.link,
        TypeFlag.symlink,
      ].contains(header.typeFlag)) {
        throw FormatException('Unsupported archive member: ${header.name}');
      }
      final bytes = await reader.current.contents.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      members[name] = (header: header, bytes: bytes);
    }
  } finally {
    await reader.cancel();
  }
  String local(String name) =>
      p.joinAll([destination.path, ...name.split('/')]);
  for (final entry in members.entries) {
    final parts = entry.key.split('/');
    for (var count = 1; count <= parts.length; count++) {
      final parent = parts.take(count).join('/');
      if (count < parts.length &&
              members[parent]?.header.typeFlag == TypeFlag.symlink ||
          FileSystemEntity.isLinkSync(local(parent))) {
        throw FormatException(
          'Archive member traverses an alias: ${entry.key}',
        );
      }
    }
    final header = entry.value.header;
    if (header.typeFlag == TypeFlag.symlink) {
      final link = header.linkName!;
      if (p.posix.isAbsolute(link) ||
          link.contains(r'\') ||
          link.contains(':')) {
        throw FormatException('Invalid symbolic link target: ${entry.key}');
      }
      final target = _archivePath(
        p.posix.join(p.posix.dirname(entry.key), link),
      );
      if (members[target]?.header.typeFlag != TypeFlag.dir) {
        throw FormatException(
          'Symbolic link target is not an archived directory: ${entry.key}',
        );
      }
    } else if (header.typeFlag == TypeFlag.link) {
      final target = _archivePath(header.linkName!);
      if (members[target]?.header.typeFlag != TypeFlag.reg) {
        throw FormatException(
          'Hard link target is not an archived file: ${entry.key}',
        );
      }
    }
  }
  destination.createSync(recursive: true);
  for (final entry in members.entries) {
    final header = entry.value.header;
    final path = local(entry.key);
    if (header.typeFlag == TypeFlag.dir) {
      Directory(path).createSync(recursive: true);
    } else if (header.typeFlag == TypeFlag.reg) {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsBytesSync(entry.value.bytes);
      if (!Platform.isWindows)
        posix.chmod(path, (header.mode & 0x1ff).toRadixString(8));
    }
  }
  for (final entry in members.entries.where(
    (e) => e.value.header.typeFlag == TypeFlag.link,
  )) {
    final path = local(entry.key),
        target = local(_archivePath(entry.value.header.linkName!));
    File(path).parent.createSync(recursive: true);
    if (Platform.isWindows) {
      _windowsLink(path, target, hard: true);
    } else {
      posix.link(target, path);
    }
  }
  for (final entry in members.entries.where(
    (e) => e.value.header.typeFlag == TypeFlag.symlink,
  )) {
    final path = local(entry.key);
    final target = entry.value.header.linkName!.replaceAll(
      '/',
      Platform.pathSeparator,
    );
    File(path).parent.createSync(recursive: true);
    if (Platform.isWindows) {
      _windowsLink(path, target, hard: false);
    } else {
      Link(path).createSync(target);
    }
    if (!FileSystemEntity.isLinkSync(path) ||
        Link(path).targetSync() != target ||
        !Directory(path).existsSync() ||
        Directory(path).resolveSymbolicLinksSync() !=
            Directory(p.join(p.dirname(path), target))
                .resolveSymbolicLinksSync()) {
      throw StateError('Prepared package link is not traversable: $path');
    }
  }
}

void _windowsLink(String path, String target, {required bool hard}) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final hardLink = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
      >('CreateHardLinkW');
  final symlink = kernel
      .lookupFunction<
        Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('CreateSymbolicLinkW');
  using((arena) {
    final name = path.toNativeUtf16(allocator: arena),
        value = target.toNativeUtf16(allocator: arena);
    var result = hard
        ? hardLink(name, value, nullptr)
        : symlink(name, value, 3);
    var code = result == 0 ? error() : 0;
    if (!hard && result == 0 && code == 87) {
      result = symlink(
        name,
        value,
        1,
      ); // Directory link; retry without developer-mode flag.
      code = result == 0 ? error() : 0;
    }
    if (result == 0)
      throw FileSystemException(
        'Create fixture link',
        path,
        OSError('Win32', code),
      );
  });
}
