import 'package:unorm_dart/unorm_dart.dart' as unicode;

String normalizeRepositoryPath(
  String raw, {
  bool file = false,
  bool directory = false,
}) {
  final value = unicode.nfc(raw.replaceAll('\\', '/'));
  if (value.isEmpty ||
      value.startsWith('/') ||
      RegExp(r'[\x00-\x1f\x7f:*?"<>|\[\]{}]').hasMatch(value)) {
    throw const FormatException(
      'Expected a portable repository-relative path.',
    );
  }
  if (file &&
      (value.endsWith('/') || {'.', '..'}.contains(value.split('/').last))) {
    throw const FormatException('Expected an exact file path.');
  }
  final segments = <String>[];
  for (final part in value.split('/')) {
    if (part == '' || part == '.') continue;
    if (part == '..') {
      if (segments.isEmpty)
        throw const FormatException('Path escapes repository root.');
      segments.removeLast();
      continue;
    }
    if (part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part)) {
      throw const FormatException('Path contains a nonportable component.');
    }
    segments.add(part);
  }
  if (segments.isEmpty) {
    if (file) throw const FormatException('Expected an exact file path.');
    return './';
  }
  return segments.join('/') + (directory || value.endsWith('/') ? '/' : '');
}

bool repositoryPathMatches(String pattern, String path) =>
    pattern == './' ||
    (pattern.endsWith('/') ? path.startsWith(pattern) : pattern == path);

/// Stable code-point ordering for normalized policy paths and text.
int comparePlanText(String a, String b) {
  final left = a.runes.iterator;
  final right = b.runes.iterator;
  while (left.moveNext()) {
    if (!right.moveNext()) return 1;
    final difference = left.current.compareTo(right.current);
    if (difference != 0) return difference;
  }
  return right.moveNext() ? -1 : 0;
}
