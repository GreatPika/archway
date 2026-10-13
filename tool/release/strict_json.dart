// Bounded JSON parsing shared by release evidence and archive manifests.
import 'dart:convert';

const maxEvidenceJsonBytes = 2 * 1024 * 1024;

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
