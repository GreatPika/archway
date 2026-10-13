import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:tar/tar.dart';

import 'archive_input.dart';

/// Verifies an owned, bounded TAR snapshot; never extracts or publishes files.
Future<void> verifyTarInput(
  ArchiveInput input,
  ArchiveInventory inventory,
) async {
  final expectedMembers = _preflight(input, inventory);
  inventory.checkMembers(expectedMembers);
  await _readTar(input, inventory, expectedMembers);
}

/// Provides verified extracted files only during [inspect], then removes them.
/// [setMode] is a private fixture seam; callers normally use native permissions.
Future<T> withTarExtraction<T>(
  ArchiveInput input,
  ArchiveInventory inventory,
  Future<T> Function(Directory directory) inspect, {
  Directory? temporaryParent,
  void Function(String path, int mode) setMode = _setMode,
}) async {
  final members = _preflight(input, inventory);
  inventory.checkMembers(members);
  final directory = await (temporaryParent ?? input.file.parent).createTemp(
    '.archway-extract-',
  );
  try {
    _setMode(directory.path, 0x1c0);
    await _readTar(
      input,
      inventory,
      members,
      directory: directory,
      setMode: setMode,
    );
    return await inspect(Directory(await directory.resolveSymbolicLinks()));
  } finally {
    await directory.delete(recursive: true);
  }
}

void _setMode(String path, int mode) {
  // Windows checks archive-mode provenance but cannot reproduce Unix modes.
  if (!Platform.isWindows) posix.chmod(path, mode.toRadixString(8));
}

Future<void> _readTar(
  ArchiveInput input,
  ArchiveInventory inventory,
  List<ArchiveMember> expectedMembers, {
  Directory? directory,
  void Function(String path, int mode) setMode = _setMode,
}) async {
  final reader = TarReader(
    input.file.openRead(),
    maxSpecialFileSize: 1024 * 1024,
  );
  var index = 0;
  try {
    while (await reader.moveNext()) {
      final header = reader.current.header;
      final member = (name: header.name, size: header.size, mode: header.mode);
      if (index >= expectedMembers.length ||
          member != expectedMembers[index++] ||
          header.typeFlag != TypeFlag.reg ||
          (header.linkName ?? '').isNotEmpty) {
        throw const FormatException('TAR reader disagrees with preflight');
      }
      final expected = inventory.files[header.name];
      RandomAccessFile? output;
      try {
        if (directory != null) {
          final file = File(
            p.joinAll([directory.path, ...header.name.split('/')]),
          );
          await file.parent.create(recursive: true);
          await file.create(exclusive: true);
          output = await file.open(mode: FileMode.write);
        }
        var size = 0;
        final digest = await crypto.sha256
            .bind(
              reader.current.contents.asyncMap((block) async {
                size += block.length;
                if (expected == null || size > expected.size) {
                  throw const FormatException('Unexpected TAR content size');
                }
                await output?.writeFrom(block);
                return block;
              }),
            )
            .first;
        if (expected == null ||
            size != expected.size ||
            digest.toString() != expected.sha256) {
          throw const FormatException('TAR content differs from inventory');
        }
      } finally {
        await output?.close();
      }
      if (directory != null)
        setMode(
          p.joinAll([directory.path, ...header.name.split('/')]),
          header.mode,
        );
    }
    if (index != expectedMembers.length)
      throw const FormatException('Missing TAR members');
  } finally {
    await reader.cancel();
  }
}

List<ArchiveMember> _preflight(ArchiveInput input, ArchiveInventory inventory) {
  if (input.size > maxArchiveBytes || input.size % 512 != 0) {
    throw const FormatException('Unaligned or oversized TAR snapshot');
  }
  final file = input.file.openSync();
  final members = <ArchiveMember>[];
  try {
    var offset = 0;
    Map<String, String>? pax;
    while (offset < input.size) {
      final bytes = _read(file, offset, 512);
      if (bytes.every((byte) => byte == 0)) {
        if (pax != null || input.size - offset < 1024)
          throw const FormatException('Short TAR terminator');
        _zero(file, offset, input.size);
        return members;
      }
      final header = _header(bytes);
      final size = header.fileSize;
      if (size > (header.typeFlag == 'x' ? 1024 * 1024 : maxArchiveFileBytes)) {
        throw const FormatException('TAR entry exceeds bound');
      }
      final end = offset + 512 + size;
      final next = offset + 512 + ((size + 511) ~/ 512) * 512;
      if (next > input.size) throw const FormatException('Truncated TAR body');
      _zero(file, end, next);
      if (header.typeFlag == 'x') {
        if (pax != null || size > 1024 * 1024)
          throw const FormatException('Invalid PAX sequence or size');
        pax = _pax(_read(file, offset + 512, size));
      } else {
        final name = pax?['path'] ?? header.filename;
        final expected = inventory.files[name];
        if (expected == null ||
            size != expected.size ||
            header.mode != expected.mode ||
            members.length >= inventory.files.length) {
          throw const FormatException('Unexpected TAR member metadata');
        }
        members.add((name: name, size: size, mode: header.mode));
        pax = null;
      }
      offset = next;
    }
    throw const FormatException('Missing TAR terminator');
  } finally {
    file.closeSync();
  }
}

Uint8List _read(RandomAccessFile file, int offset, int count) {
  file.setPositionSync(offset);
  final bytes = file.readSync(count);
  if (bytes.length != count)
    throw const FormatException('Truncated TAR snapshot');
  return bytes;
}

void _zero(RandomAccessFile file, int start, int end) {
  while (start < end) {
    final bytes = _read(file, start, min(65536, end - start));
    if (bytes.any((byte) => byte != 0))
      throw const FormatException('Nonzero TAR padding');
    start += bytes.length;
  }
}

Map<String, String> _pax(Uint8List bytes) {
  final fields = <String, String>{};
  var offset = 0;
  while (offset < bytes.length) {
    final space = bytes.indexOf(32, offset);
    if (space < 0 || space - offset > 8)
      throw const FormatException('Invalid PAX length');
    final number = ascii.decode(bytes.sublist(offset, space));
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(number))
      throw const FormatException('Invalid PAX length');
    final end = offset + int.parse(number);
    if (end <= space + 2 || end > bytes.length || bytes[end - 1] != 10) {
      throw const FormatException('Invalid PAX frame');
    }
    final record = utf8.decode(bytes.sublist(space + 1, end - 1));
    final equals = record.indexOf('=');
    if (equals <= 0) throw const FormatException('Invalid PAX key');
    final key = record.substring(0, equals),
        value = record.substring(equals + 1);
    if (!{
          'path',
          'mtime',
          'atime',
          'ctime',
          'uid',
          'gid',
          'uname',
          'gname',
        }.contains(key) ||
        fields.containsKey(key) ||
        value.isEmpty ||
        value.contains('\x00')) {
      throw const FormatException('Unsupported or ambiguous PAX metadata');
    }
    fields[key] = value;
    offset = end;
  }
  return fields;
}

// TarFile parses numeric fields but tolerates malformed octal and trims names.
// Constrain the owned header subset before parsing, then restore exact strings.
archive.TarFile _header(Uint8List bytes) {
  if (![0, 48, 120].contains(bytes[156]) ||
      bytes.sublist(157, 257).any((b) => b != 0)) {
    throw const FormatException('Unsupported TAR type or link target');
  }
  for (final (start, length) in [
    (100, 8),
    (108, 8),
    (116, 8),
    (124, 12),
    (136, 12),
    (148, 8),
    (329, 8),
    (337, 8),
  ]) {
    if (!RegExp(r'^ *(?:[0-7]+)?[ \x00]*$')
        .hasMatch(ascii.decode(bytes.sublist(start, start + length)))) {
      throw const FormatException('Unsupported TAR numeric field');
    }
  }
  final header = archive.TarFile.read(
    archive.InputMemoryStream(bytes),
    storeData: false,
  );
  var checksum = 0;
  for (var i = 0; i < 512; i++) {
    checksum += i >= 148 && i < 156 ? 32 : bytes[i];
  }
  if (checksum != header.checksum)
    throw const FormatException('Invalid TAR header checksum');
  String text(int start, int count) {
    final field = bytes.sublist(start, start + count);
    final end = field.indexOf(0);
    return utf8.decode(field.sublist(0, end < 0 ? null : end));
  }

  header.filename = text(0, 100);
  if (header.ustarIndicator == 'ustar' && text(345, 155).isNotEmpty) {
    header.filename = '${text(345, 155)}/${header.filename}';
  }
  return header;
}
