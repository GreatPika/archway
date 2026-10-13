// Original, bounded execution evidence shared by native and source validators.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../validation/json_values.dart';

const maxEvidenceFileBytes = 128 * 1024 * 1024;
const maxEvidenceJsonBytes = 2 * 1024 * 1024;

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

/// Small evidence-only JSON reader: bounded depth and decoded unique keys.
Object? decodeEvidenceJson(String text) {
  if (text.length > maxEvidenceJsonBytes ||
      utf8.encode(text).length > maxEvidenceJsonBytes) {
    throw const FormatException('Evidence JSON exceeds bound');
  }
  final reader = _EvidenceJson(text);
  final result = reader.value(0);
  reader.whitespace();
  if (reader.offset != text.length) reader.fail();
  return result;
}

class _EvidenceJson {
  _EvidenceJson(this.text);
  final String text;
  int offset = 0;
  static final scalar = RegExp(
    r'"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"'
    r'|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
    r'|true|false|null',
  );

  Never fail() =>
      throw FormatException('Invalid or duplicate evidence JSON', text, offset);

  void whitespace() {
    while (offset < text.length &&
        [32, 9, 10, 13].contains(text.codeUnitAt(offset))) {
      offset++;
    }
  }

  bool take(String token) {
    whitespace();
    if (!text.startsWith(token, offset)) return false;
    offset += token.length;
    return true;
  }

  Object? value(int depth) {
    if (depth > 128) fail();
    if (take('{')) {
      final object = <String, Object?>{};
      if (take('}')) return object;
      do {
        whitespace();
        if (offset >= text.length || text[offset] != '"') fail();
        final key = atom();
        if (key is! String || object.containsKey(key) || !take(':')) fail();
        object[key] = value(depth + 1);
        if (take('}')) return object;
      } while (take(','));
      fail();
    }
    if (take('[')) {
      final array = <Object?>[];
      if (take(']')) return array;
      do {
        array.add(value(depth + 1));
        if (take(']')) return array;
      } while (take(','));
      fail();
    }
    whitespace();
    return atom();
  }

  Object? atom() {
    final match = scalar.matchAsPrefix(text, offset);
    if (match == null) fail();
    offset = match.end;
    final result = jsonDecode(match[0]!);
    if (result is num && !result.isFinite) fail();
    return result;
  }
}

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
      receipt['timeout_seconds'] != 600 ||
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
