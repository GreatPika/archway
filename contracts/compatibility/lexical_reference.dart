import 'package:unorm_dart/unorm_dart.dart' as unicode;

/// Finite lexical specification model, not Archway or OS certification.
String normalize(Object? raw) {
  if (raw is! String || raw.isEmpty) throw FormatException('empty');
  final value = unicode.nfc(raw.replaceAll(r'\', '/'));
  if (value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
    throw FormatException('absolute');
  }
  if (value.runes.any((c) => c < 32 || c == 127) ||
      value.contains(RegExp(r'[:*?"<>|\[\]{}]'))) {
    throw FormatException('reserved');
  }
  final parts = <String>[];
  for (final part in value.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) throw FormatException('escape');
      parts.removeLast();
      continue;
    }
    if (part.endsWith(' ') || part.endsWith('.')) {
      throw FormatException('trailing');
    }
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
      caseSensitive: false,
    ).hasMatch(part.split('.').first)) {
      throw FormatException('device');
    }
    parts.add(part);
  }
  if (parts.isEmpty) return './';
  return '${parts.join('/')}${value.endsWith('/') ? '/' : ''}';
}

bool matches(String pattern, String path) =>
    pattern == './' ||
    (pattern.endsWith('/') ? path.startsWith(pattern) : path == pattern);
