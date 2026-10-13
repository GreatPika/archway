// Developer-only verification of release_bundles.py's files-only ZIP subset.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart' as crypto;

import 'archive_input.dart';

/// Returns CRC-checked root manifest bytes, not a verified bundle inventory.
/// The caller must parse these bounded bytes then call [verifyZipInput].
Future<Uint8List> readZipManifest(ArchiveInput input) async {
  final entries = _preflight(input);
  final matches = entries.where((entry) => entry.name == 'manifest.json');
  if (matches.length != 1 || matches.single.size > maxArchiveJsonBytes) {
    throw const FormatException('Missing or oversized root ZIP manifest');
  }
  final output = BytesBuilder(copy: false);
  _decode(
    input,
    entries,
    (entry) => entry.name == 'manifest.json',
    (entry, bytes) => output.add(bytes),
  );
  return output.takeBytes();
}

/// Verifies an owned ZIP snapshot; never extracts or publishes its members.
Future<void> verifyZipInput(
  ArchiveInput input,
  ArchiveInventory inventory,
) async {
  final entries = _preflight(input);
  inventory.checkMembers(
    entries.map((e) => (name: e.name, size: e.size, mode: e.mode)),
  );
  _decode(input, entries, (_) => true, null, inventory: inventory);
}

typedef _Entry = ({String name, int size, int mode, int crc});

// No ZIP64, descriptors, comments, extras, encryption, directories, links, or
// self-extracting prefixes. The producer writes contiguous seekable deflate ZIPs.
List<_Entry> _preflight(ArchiveInput input) {
  if (input.size < 22 || input.size > maxArchiveBytes) {
    throw const FormatException('Invalid ZIP snapshot size');
  }
  final file = input.file.openSync();
  try {
    Uint8List read(int offset, int count) {
      if (offset < 0 || count < 0 || offset + count > input.size) {
        throw const FormatException('Truncated ZIP structure');
      }
      file.setPositionSync(offset);
      final bytes = file.readSync(count);
      if (bytes.length != count)
        throw const FormatException('Truncated ZIP snapshot');
      return bytes;
    }

    final end = ByteData.sublistView(read(input.size - 22, 22));
    int u16(ByteData b, int n) => b.getUint16(n, Endian.little);
    int u32(ByteData b, int n) => b.getUint32(n, Endian.little);
    final count = u16(end, 10),
        centralSize = u32(end, 12),
        centralStart = u32(end, 16);
    if (u32(end, 0) != 0x06054b50 ||
        u16(end, 4) != 0 ||
        u16(end, 6) != 0 ||
        u16(end, 8) != count ||
        count > maxArchiveEntries ||
        u16(end, 20) != 0 ||
        centralStart + centralSize != input.size - 22) {
      throw const FormatException('Unsupported ZIP end record');
    }
    var offset = centralStart, localOffset = 0;
    final entries = <_Entry>[];
    final identities = <String, ArchiveFileIdentity>{};
    for (var i = 0; i < count; i++) {
      if (offset + 46 > input.size - 22)
        throw const FormatException('Short ZIP directory');
      final central = ByteData.sublistView(read(offset, 46));
      final flags = u16(central, 8),
          size = u32(central, 24),
          compressed = u32(central, 20);
      final nameLength = u16(central, 28),
          attributes = u32(central, 38),
          mode = attributes >> 16;
      if (u32(central, 0) != 0x02014b50 ||
          ![20, 0x314].contains(u16(central, 4)) ||
          u16(central, 6) != 20 ||
          ![0, 0x800].contains(flags) ||
          u16(central, 10) != 8 ||
          size > maxArchiveFileBytes ||
          compressed > maxArchiveBytes ||
          nameLength == 0 ||
          u16(central, 30) != 0 ||
          u16(central, 32) != 0 ||
          u16(central, 34) != 0 ||
          u16(central, 36) != 0 ||
          (attributes & 0xffff) != 0 ||
          (mode & 0xf000) != 0x8000 ||
          (mode & 0xe00) != 0 ||
          u32(central, 42) != localOffset ||
          offset + 46 + nameLength > input.size - 22) {
        throw const FormatException('Unsupported ZIP member metadata');
      }
      final nameBytes = read(offset + 46, nameLength);
      final name = flags == 0
          ? ascii.decode(nameBytes)
          : utf8.decode(nameBytes);
      if (identities.containsKey(name))
        throw const FormatException('Duplicate ZIP member');
      final local = ByteData.sublistView(read(localOffset, 30));
      if (u32(local, 0) != 0x04034b50 ||
          u16(local, 26) != nameLength ||
          u16(local, 28) != 0) {
        throw const FormatException('Unsupported ZIP local header');
      }
      // Compare every shared field before ZipFile replaces local sizes with central sizes.
      for (var j = 0; j < 22; j++) {
        if (local.getUint8(4 + j) != central.getUint8(6 + j)) {
          throw const FormatException('ZIP local and central headers disagree');
        }
      }
      final localName = read(localOffset + 30, nameLength);
      for (var j = 0; j < nameLength; j++) {
        if (localName[j] != nameBytes[j])
          throw const FormatException('ZIP names disagree');
      }
      localOffset += 30 + nameLength + compressed;
      if (localOffset > centralStart)
        throw const FormatException('ZIP member overlaps directory');
      final permissions = mode & 0xfff;
      identities[name] = (size: size, mode: permissions, sha256: '0' * 64);
      entries.add((
        name: name,
        size: size,
        mode: permissions,
        crc: u32(central, 16),
      ));
      offset += 46 + nameLength;
    }
    if (localOffset != centralStart || offset != input.size - 22) {
      throw const FormatException('ZIP structure has unclaimed bytes');
    }
    // Reuse the portable path, alias, file-prefix, count and total-size policy.
    ArchiveInventory(identities);
    return entries;
  } finally {
    file.closeSync();
  }
}

void _decode(
  ArchiveInput input,
  List<_Entry> entries,
  bool Function(_Entry) select,
  void Function(_Entry, Uint8List)? collect, {
  ArchiveInventory? inventory,
}) {
  final stream = archive.InputFileStream(input.file.path);
  try {
    final decoder = archive.ZipDecoder();
    decoder.decodeStream(stream);
    final headers = decoder.directory.fileHeaders;
    if (headers.length != entries.length)
      throw const FormatException('ZIP decoder count mismatch');
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i], file = headers[i].file;
      if (file == null ||
          file.filename != entry.name ||
          file.uncompressedSize != entry.size) {
        throw const FormatException('ZIP decoder disagrees with preflight');
      }
      if (!select(entry)) continue;
      final output = _CheckedOutput(
        entry.size,
        collect == null ? null : (bytes) => collect(entry, bytes),
      );
      try {
        // Like Python zipfile, the native raw codec can accept unused deflate
        // tails or a missing terminator after complete output. This verifies
        // expanded identity, not canonical compressed framing; ArchiveInput's
        // digest independently binds every original compressed byte.
        file.decompress(output);
      } finally {
        output.hash.close();
      }
      if (output.length != entry.size ||
          output.crc != entry.crc ||
          (inventory != null &&
              output.digest.value.toString() !=
                  inventory.files[entry.name]!.sha256)) {
        throw const FormatException(
          'ZIP content differs from inventory or CRC',
        );
      }
    }
  } finally {
    stream.closeSync();
  }
}

final class _Digest implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

final class _CheckedOutput extends archive.OutputStream {
  _CheckedOutput(this.limit, this.collect)
    : super(byteOrder: archive.ByteOrder.littleEndian) {
    hash = crypto.sha256.startChunkedConversion(digest);
  }
  final int limit;
  final void Function(Uint8List)? collect;
  final digest = _Digest();
  late final ByteConversionSink hash;
  int crc = 0;
  @override
  int length = 0;
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length || this.length + count > limit) {
      throw const FormatException('Expanded ZIP member exceeds bound');
    }
    final block = Uint8List.fromList(bytes.take(count).toList());
    this.length += count;
    hash.add(block);
    crc = archive.getCrc32(block, crc);
    collect?.call(block);
  }

  @override
  void writeByte(int value) => writeBytes([value]);
  @override
  void writeStream(archive.InputStream stream) {
    while (!stream.isEOS)
      writeBytes(stream.readBytes(min(65536, stream.length)).toUint8List());
  }

  @override
  void flush() {}
  @override
  void clear() => throw UnsupportedError('ZIP verification is append-only');
  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('ZIP verification has no output buffer');
}
