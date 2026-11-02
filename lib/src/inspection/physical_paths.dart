import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../native/physical_paths.dart';
import '../plan/repository_path.dart';

Future<void> preparePhysicalLinks() => PhysicalPaths.prepare();
List<Map<String, String>> symlinkHops(String native) =>
    PhysicalPaths.trace(native).hops;

String? publicPhysicalPath(String? relative) {
  if (relative == null) return null;
  try {
    return normalizeRepositoryPath(relative) == relative ? relative : null;
  } on FormatException {
    return null;
  }
}

// repositoryRelativePath supplies normalized root-relative syntax. Input evidence describes
// actual names, not Plan operands: literal '*', brackets, and device names are
// still representable. Preserve other names as absolute URIs rather than
// rewriting a backslash or a non-NFC physical identity into another pathname.
String? inputPhysicalPath(String? relative) {
  if (relative == null ||
      relative.contains('\\') ||
      relative.contains('\x00') ||
      RegExp(r'^[A-Za-z]:').hasMatch(relative) ||
      unicode.nfc(relative) != relative) {
    return null;
  }
  return relative;
}

String fileUri(String native) => File(native).uri.toString();
String? repositoryRelativePath(String root, String native) {
  if (native == root) return './';
  if (!p.isWithin(root, native)) return null;
  return p.relative(native, from: root).split(p.separator).join('/');
}
