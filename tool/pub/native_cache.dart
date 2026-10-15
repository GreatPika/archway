// Private pub cache ownership; descriptor bytes are embedded by package staging.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/archive_extraction.dart';
import '../release/archive_input.dart';
import '../release/gzip_input.dart';
import '../release/native_archive.dart';
import '../release/native_manifest.dart';
import '../release/tar_input.dart';
import '../release/zip_input.dart';
import '../validation/json_values.dart';
import 'download.dart';

const _targets = ['linux-x64', 'macos-arm64', 'windows-x64'];
typedef NativeDownload = Future<void> Function(
  Uri url,
  File destination,
  int size,
);

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

/// [download] is a private transport fixture seam, never a launcher option.
Future<File> acquirePubNative(
  Map<String, Object?> descriptor,
  String target,
  Directory cache, {
  NativeDownload download = downloadNativeArchive,
}) async {
  _require(_targets.contains(target), 'Unsupported native target: $target');
  final version = descriptor['version'], source = descriptor['source'];
  final targets = descriptor['targets'];
  _require(
    descriptor.length == 4 &&
        descriptor['schema_version'] is int &&
        descriptor['schema_version'] == 1 &&
        version is String &&
        version.length <= 200 &&
        RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$')
            .hasMatch(version) &&
        source is Map<String, Object?> &&
        targets is Map &&
        targets.length == 3 &&
        _targets.every(targets.containsKey),
    'Invalid embedded acquisition descriptor',
  );
  final selected = (targets as Map)[target];
  bool digest(Object? value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  _require(
    selected is Map &&
        selected.length == 4 &&
        selected['url'] is String &&
        selected['size'] is int &&
        selected['size'] > 0 &&
        selected['size'] <= maxArchiveBytes &&
        digest(selected['sha256']) &&
        digest(selected['manifest_sha256']),
    'Invalid embedded native payload identity',
  );
  final url = Uri.parse(selected['url'] as String);
  _require(
    url.scheme == 'https' &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        !url.hasFragment,
    'Invalid embedded native payload URL',
  );
  final expected = (
    size: selected['size'] as int,
    sha256: selected['sha256'] as String,
  );
  final parent = Directory(
    p.join(cache.absolute.path, version as String, target),
  );
  _prepareDirectory(parent);
  final destination = Directory(p.join(parent.path, expected.sha256));
  final executable =
      'bin/$target/archway${target == 'windows-x64' ? '.exe' : ''}';
  void checkManifest(
    Map<String, Object?> value,
    String hash,
    ArchiveInventory inventory,
  ) {
    _require(
      hash == selected['manifest_sha256'] &&
          value['version'] == version &&
          value['target'] == target &&
          sameJson(value['source'], source),
      'Native manifest differs from pinned release',
    );
    _require(
      inventory.files[executable] != null &&
          inventory.files[executable]!.size > 0,
      'Pinned native executable is missing',
    );
  }

  Future<File> warm() async {
    _require(
      FileSystemEntity.typeSync(destination.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          destination.resolveSymbolicLinksSync() == destination.path,
      'Native cache destination is not an ordinary canonical directory',
    );
    final manifest = await readNativeManifest(
      File(p.join(destination.path, 'manifest.json')),
    );
    checkManifest(
      manifest.manifest,
      manifest.manifestSha256,
      manifest.completeArchiveInventory,
    );
    final file = File(p.joinAll([destination.path, ...executable.split('/')]));
    final identity = manifest.completeArchiveInventory.files[executable]!;
    await withArchiveInput(
      file,
      (_) async {},
      expected: (size: identity.size, sha256: identity.sha256),
      maxBytes: maxArchiveFileBytes,
      temporaryParent: parent,
    );
    return file;
  }

  if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return warm();
  }
  final workspace = await parent.createTemp('.archway-download-');
  try {
    setArchiveMode(workspace.path, 0x1c0);
    final archive = File(p.join(workspace.path, 'payload'));
    await download(url, archive, expected.size);
    final verified = await verifyNativeArchive(
      archive,
      format: target == 'windows-x64'
          ? NativeArchiveFormat.zip
          : NativeArchiveFormat.tarGzip,
      expected: expected,
      temporaryParent: workspace,
    );
    checkManifest(
      verified.manifest,
      verified.manifestSha256,
      verified.completeArchiveInventory,
    );
    try {
      await withArchiveInput(
        archive,
        (input) async {
          if (target == 'windows-x64') {
            await withZipExtraction(
              input,
              verified.completeArchiveInventory,
              (_) async {},
              publishTo: destination,
            );
          } else {
            await withGzipSnapshot(
              input,
              (expanded) => withArchiveInput(
                expanded,
                (tar) => withTarExtraction(
                  tar,
                  verified.completeArchiveInventory,
                  (_) async {},
                  publishTo: destination,
                ),
                temporaryParent: workspace,
              ),
            );
          }
        },
        expected: expected,
        temporaryParent: workspace,
      );
    } on ArchiveDestinationExists {
      // Only a publication collision admits a winner; decode/callback failures do not.
      return await warm();
    }
    return await warm();
  } finally {
    await workspace.delete(recursive: true);
  }
}

void _prepareDirectory(Directory directory) {
  _require(
    p.normalize(directory.path) == directory.path,
    'Noncanonical native cache path',
  );
  final missing = <Directory>[];
  var parent = directory;
  while (FileSystemEntity.typeSync(parent.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    missing.add(parent);
    parent = parent.parent;
  }
  _require(
    FileSystemEntity.typeSync(parent.path, followLinks: false) ==
            FileSystemEntityType.directory &&
        parent.resolveSymbolicLinksSync() == parent.path,
    'Aliased native cache parent',
  );
  for (final item in missing.reversed) {
    item.createSync();
    _require(
      FileSystemEntity.typeSync(item.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          item.resolveSymbolicLinksSync() == item.path,
      'Aliased native cache parent',
    );
    setArchiveMode(item.path, 0x1c0);
  }
}
