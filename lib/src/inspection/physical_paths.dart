part of 'inspection.dart';

Future<void> _preparePhysicalLinks() => PhysicalPaths.prepare();
List<Map<String, String>> _symlinkHops(String native) =>
    PhysicalPaths.trace(native).hops;

String? _publicPhysicalPath(String? relative) {
  if (relative == null) return null;
  try {
    return normalizeRepositoryPath(relative) == relative ? relative : null;
  } on FormatException {
    return null;
  }
}

// _relative supplies normalized root-relative syntax. Input evidence describes
// actual names, not Plan operands: literal '*', brackets, and device names are
// still representable. Preserve other names as absolute URIs rather than
// rewriting a backslash or a non-NFC physical identity into another pathname.
String? _inputPhysicalPath(String? relative) {
  if (relative == null ||
      relative.contains('\\') ||
      relative.contains('\x00') ||
      RegExp(r'^[A-Za-z]:').hasMatch(relative) ||
      unicode.nfc(relative) != relative) {
    return null;
  }
  return relative;
}
