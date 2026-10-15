// Identify the SDK-selected wrapper within its isolated hosted cache.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/installation_artifact.dart';
import 'release_execution_receipts.dart';

Future<Directory> inspectActivatedPubPackage(
  Directory cache,
  ArchiveInventory expected,
) async {
  final config = File(
    p.join(
      cache.path,
      'global_packages',
      'archway',
      '.dart_tool',
      'package_config.json',
    ),
  );
  final record = readRecord(config);
  if (record is! Map ||
      record['configVersion'] != 2 ||
      record['packages'] is! List) {
    throw const FormatException('Invalid activated pub package configuration');
  }
  final packages = record['packages'] as List;
  if (packages.length > maxArchiveEntries ||
      packages.any((entry) => entry is! Map)) {
    throw const FormatException('Invalid activated package inventory');
  }
  final selected = packages
      .where((entry) => entry['name'] == 'archway')
      .toList();
  if (selected.length != 1 || selected.single['rootUri'] is! String) {
    throw const FormatException(
      'Activated archway package is missing or ambiguous',
    );
  }
  final uri = config.uri.resolve(selected.single['rootUri'] as String);
  if (uri.scheme != 'file' ||
      uri.authority.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Activated package requires a local file URI');
  }
  final root = Directory(p.normalize(Directory.fromUri(uri).absolute.path));
  if (!p.isWithin(p.join(cache.path, 'hosted'), root.path)) {
    throw const FormatException(
      'Activated package is outside its isolated hosted cache',
    );
  }
  if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !sameEvidencePath(
        root.resolveSymbolicLinksSync(),
        root.path,
        p.context,
      )) {
    throw const FormatException('Activated package is aliased or nonordinary');
  }
  final canonical = Directory(root.resolveSymbolicLinksSync());
  await verifyInstallationDirectory(canonical, expected, compareModes: false);
  return canonical;
}
