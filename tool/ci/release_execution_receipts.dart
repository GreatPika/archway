// Original, bounded execution evidence shared by native and source validators.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import '../release/strict_json.dart';

export '../release/strict_json.dart'
    show decodeEvidenceJson, maxEvidenceJsonBytes;

const maxEvidenceFileBytes = 128 * 1024 * 1024;

List<int> readOrdinaryBytes(File file, {int limit = maxEvidenceFileBytes}) {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      !sameEvidencePath(
        file.resolveSymbolicLinksSync(),
        file.absolute.path,
        p.context,
      )) {
    throw const FormatException('Aliased or nonordinary evidence file');
  }
  final input = file.openSync();
  try {
    if (input.lengthSync() > limit) {
      throw const FormatException('Evidence file exceeds bound');
    }
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final chunk = input.readSync((limit - bytes.length + 1).clamp(1, 65536));
      if (chunk.isEmpty) return bytes.takeBytes();
      bytes.add(chunk);
      if (bytes.length > limit) {
        throw const FormatException('Evidence file exceeds bound');
      }
    }
  } finally {
    input.closeSync();
  }
}

List<int> verifiedBytes(File file, Object? digest) {
  if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const FormatException('Malformed evidence digest');
  }
  final bytes = readOrdinaryBytes(file);
  if (sha256.convert(bytes).toString() != digest) {
    throw const FormatException('Original evidence hash differs');
  }
  return bytes;
}

Object? readRecord(File file) => decodeEvidenceJson(
  utf8.decode(readOrdinaryBytes(file, limit: maxEvidenceJsonBytes)),
);

/// Target-aware lexical identity, preserving parent components and POSIX roots.
bool sameEvidencePath(String a, String b, p.Context paths) {
  // PurePosixPath preserves exactly two leading slashes as a distinct root.
  bool doubleRoot(String path) =>
      path.startsWith('//') && !path.startsWith('///');
  if (paths.style == p.Style.posix && doubleRoot(a) != doubleRoot(b)) {
    return false;
  }
  List<String> parts(String value) => paths
      .split(value)
      .where((part) => part.isNotEmpty && part != '.')
      .map(
        (part) => paths.style == p.Style.windows
            ? part.replaceAll('/', r'\').toLowerCase()
            : part,
      )
      .toList();
  return sameJson(parts(a), parts(b));
}

Map<String, List<int>> validateExecution(
  Object? receipt,
  List<String> command,
  Directory directory,
  p.Context paths, {
  required String suite,
  int expectedTimeout = 600,
}) {
  const fields = {
    'suite',
    'command',
    'exit_code',
    'timed_out',
    'elapsed_seconds',
    'timeout_seconds',
    'stdout',
    'stderr',
    'stdout_sha256',
    'stderr_sha256',
  };
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$').hasMatch(suite) ||
      receipt is! Map ||
      receipt.length != fields.length ||
      !fields.every(receipt.containsKey) ||
      receipt['suite'] != suite) {
    throw const FormatException('Execution receipt fields or suite differ');
  }
  final elapsed = receipt['elapsed_seconds'];
  final argv = receipt['command'];
  if (receipt['exit_code'] is! int ||
      receipt['exit_code'] != 0 ||
      receipt['timed_out'] != false ||
      receipt['timeout_seconds'] is! int ||
      receipt['timeout_seconds'] != expectedTimeout ||
      elapsed is! num ||
      !elapsed.isFinite ||
      elapsed < 0 ||
      command.isEmpty ||
      argv is! List ||
      argv.length != command.length ||
      argv.any((arg) => arg is! String) ||
      !sameEvidencePath(argv[0] as String, command[0], paths) ||
      !sameJson(argv.skip(1).toList(), command.skip(1).toList())) {
    throw const FormatException(
      'Execution failed, timed out, or command differs',
    );
  }
  final original = readRecord(File(p.join(directory.path, '$suite.json')));
  if (!sameJson(original, receipt) ||
      original is! Map ||
      original['exit_code'] is! int ||
      original['timeout_seconds'] is! int) {
    throw const FormatException('Original execution receipt differs');
  }
  return {
    for (final stream in ['stdout', 'stderr'])
      stream: _stream(receipt, directory, suite, stream),
  };
}

List<int> _stream(
  Map receipt,
  Directory directory,
  String suite,
  String stream,
) {
  final name = '$suite.$stream.log';
  if (receipt[stream] != name) {
    throw const FormatException('Execution log name differs');
  }
  return verifiedBytes(
    File(p.join(directory.path, name)),
    receipt['${stream}_sha256'],
  );
}
