// Developer-only native manifest parsing; caller policy stays with callers.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'archive_input.dart';
import 'strict_json.dart';

/// Parsed identities and original bytes, without any payload verification.
final class NativeManifest {
  NativeManifest._({
    required List<int> manifestBytes,
    required Map<String, Object?> manifest,
    required this.completeArchiveInventory,
    required this.manifestSha256,
  }) : manifestBytes = List.unmodifiable(manifestBytes),
       manifest = _freeze(manifest) as Map<String, Object?>;

  final List<int> manifestBytes;
  final Map<String, Object?> manifest;
  final ArchiveInventory completeArchiveInventory;
  final String manifestSha256;
}

/// Reads a bounded ordinary-file snapshot; never reopens the original to parse.
Future<NativeManifest> readNativeManifest(File file) => withArchiveInput(
  file,
  (snapshot) async => parseNativeManifest(await snapshot.file.readAsBytes()),
  maxBytes: maxArchiveJsonBytes,
);

/// Parses inventory identities without deciding source, target or version policy.
NativeManifest parseNativeManifest(List<int> bytes) {
  if (bytes.length > maxArchiveJsonBytes) {
    throw const FormatException('Native manifest exceeds bound');
  }
  final value = decodeEvidenceJson(utf8.decode(bytes));
  if (value is! Map<String, Object?>) {
    throw const FormatException('Native manifest must be an object');
  }
  final files = value['files'];
  if (files is! Map<String, Object?> ||
      files.isEmpty ||
      files.length >= maxArchiveEntries ||
      files.containsKey('manifest.json')) {
    throw const FormatException('Invalid native file inventory');
  }
  final identities = <String, ArchiveFileIdentity>{};
  for (final entry in files.entries) {
    final identity = entry.value;
    if (identity is! Map<String, Object?> ||
        identity.length != 3 ||
        identity['size'] is! int ||
        identity['mode'] is! int ||
        identity['sha256'] is! String) {
      throw const FormatException('Invalid native manifest entry');
    }
    identities[entry.key] = (
      size: identity['size'] as int,
      mode: identity['mode'] as int,
      sha256: identity['sha256'] as String,
    );
  }
  final manifestSha256 = crypto.sha256.convert(bytes).toString();
  identities['manifest.json'] = (
    size: bytes.length,
    mode: 0x1a4,
    sha256: manifestSha256,
  );
  return NativeManifest._(
    manifestBytes: bytes,
    manifest: value,
    completeArchiveInventory: ArchiveInventory(identities),
    manifestSha256: manifestSha256,
  );
}

// JSON has only maps, arrays and scalar leaves; retain none of its mutable lists.
Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => Map<String, Object?>.unmodifiable(
    value.map((key, item) => MapEntry(key, _freeze(item))),
  ),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
