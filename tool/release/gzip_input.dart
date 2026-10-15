// Developer-only gzip input for native archive verification and production.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:path/path.dart' as p;

import 'archive_input.dart';

/// Provides a private file only after gzip member data CRC/length verification.
/// The file is callback-scoped. Trailing bytes, including padding, are refused.
Future<T> withGzipInput<T>(
  File source,
  Future<T> Function(File expanded) inspect, {
  Directory? temporaryParent,
  ({int size, String sha256})? expected,
  int maxBytes = maxArchiveBytes,
  int maxExpandedBytes = maxArchiveBytes,
}) async {
  return withArchiveInput(
    source,
    (snapshot) =>
        withGzipSnapshot(snapshot, inspect, maxExpandedBytes: maxExpandedBytes),
    temporaryParent: temporaryParent,
    expected: expected,
    maxBytes: maxBytes,
  );
}

/// Expands an already-owned snapshot without copying its compressed bytes again.
/// The expanded file exists only for [inspect], including on callback failure.
Future<T> withGzipSnapshot<T>(
  ArchiveInput snapshot,
  Future<T> Function(File expanded) inspect, {
  int maxExpandedBytes = maxArchiveBytes,
}) async {
  if (maxExpandedBytes < 0 || maxExpandedBytes > maxArchiveBytes) {
    throw ArgumentError.value(
      maxExpandedBytes,
      'maxExpandedBytes',
      'Must tighten the archive bound',
    );
  }
  final directory = await snapshot.file.parent.createTemp('.expanded-');
  try {
    final expanded = File(p.join(directory.path, 'expanded'));
    await expanded.create(exclusive: true);
    final handle = _OutputHandle(await expanded.open(mode: FileMode.write));
    archive.InputFileStream? input;
    archive.OutputFileStream? output;
    try {
      input = archive.InputFileStream(snapshot.file.path);
      // Prevent fallback inflation: even if optional gzip headers are bad,
      // the retained 1f8b prefix fails zlib FCHECK before unbounded decoding.
      if (input.length < 10 ||
          input.readUint16() != 0x8b1f ||
          input.readByte() != 8) {
        throw const FormatException('Expected gzip header');
      }
      input.reset();
      output = archive.OutputFileStream.withFileHandle(handle);
      if (!archive.GZipDecoderWeb().decodeStream(
        input,
        _GzipOutput(output, maxExpandedBytes),
        verify: true,
      )) {
        throw const FormatException('Malformed or truncated gzip input');
      }
    } finally {
      try {
        input?.closeSync();
      } finally {
        try {
          output?.closeSync();
        } finally {
          handle.closeSync();
        }
      }
    }
    return await inspect(expanded);
  } finally {
    await directory.delete(recursive: true);
  }
}

// Adapt only the already-created private file handle; never open another path.
final class _OutputHandle extends archive.AbstractFileHandle {
  _OutputHandle(this._file);
  RandomAccessFile? _file;

  @override
  int get position => _file!.positionSync();
  @override
  set position(int value) => _file!.setPositionSync(value);
  @override
  int get length => _file!.lengthSync();
  @override
  bool get isOpen => _file != null;
  @override
  int readInto(Uint8List bytes, [int? length]) =>
      _file!.readIntoSync(bytes, 0, length);
  @override
  void writeFromSync(List<int> bytes, [int start = 0, int? end]) =>
      _file!.writeFromSync(bytes, start, end);
  @override
  Future<void> close() async {
    final file = _file;
    _file = null;
    await file?.close();
  }

  @override
  void closeSync() {
    final file = _file;
    _file = null;
    file?.closeSync();
  }
}

// GZipDecoderWeb has no output-limit parameter. Bound every append before it
// reaches the library's file-backed buffer, including deflate back-references.
final class _GzipOutput extends archive.OutputStream {
  _GzipOutput(this.file, this.limit)
    : super(byteOrder: archive.ByteOrder.littleEndian);
  final archive.OutputFileStream file;
  final int limit;
  @override
  int get length => file.length;
  void _check(int count) {
    if (count < 0 || length + count > limit) {
      throw const FormatException('Expanded gzip input exceeds bound');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    file.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    file.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(archive.InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(stream.readBytes(65536).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => file.subset(start, end);
  @override
  void flush() => file.flush();
  @override
  void clear() => throw UnsupportedError('Gzip output is append-only');
}
