// Bind finished native artifacts to the shared npm/pub acquisition descriptor.
// Local generation does not establish hosted availability or authorize upload.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../validation/json_values.dart';
import 'archive_input.dart';
import 'installation_identity.dart';
import 'native_archive.dart';
import 'native_payload.dart';
import 'publish_directory.dart';

const _repositoryUrl = 'https://github.com/GreatPika/archway';

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

Future<void> generateDescriptor({
  required Directory source,
  required Directory native,
  required Directory output,
  required String expectedCommit,
}) async {
  source = source.absolute;
  native = native.absolute;
  output = output.absolute;
  _require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Descriptor output already exists',
  );
  final identity = await sourceIdentity(source);
  _require(identity['commit'] == expectedCommit, 'Source commit differs');
  final metadata = await nativePubspec(source);
  final version = metadata['version'];
  _require(
    metadata['name'] == 'archway' &&
        metadata['repository'] == _repositoryUrl &&
        version is String &&
        Version.parse(version).toString() == version,
    'Invalid canonical release version or repository',
  );
  final receipt = await readNativeJson(
    File(p.join(native.path, 'native-packaging.json')),
  );
  _require(
    receipt['schema_version'] is int &&
        receipt['schema_version'] == 1 &&
        receipt['version'] == version &&
        sameJson(receipt['source'], identity),
    'Native producer identity differs',
  );
  final bundles = receipt['native_bundles'];
  _require(
    bundles is Map &&
        bundles.length == nativeTargets.length &&
        nativeTargets.keys.every(bundles.containsKey),
    'Native producer target set differs',
  );
  final targets = <String, Object?>{};
  for (final target in nativeTargets.keys) {
    final record = (bundles as Map)[target];
    final windows = target == 'windows-x64';
    final filename = 'archway-$version-$target${windows ? '.zip' : '.tar.gz'}';
    bool digest(Object? value) =>
        value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
    _require(
      record is Map &&
          record['filename'] == filename &&
          record['size'] is int &&
          record['size'] > 0 &&
          record['size'] <= maxArchiveBytes &&
          digest(record['sha256']) &&
          digest(record['manifest_sha256']),
      'Invalid native producer archive: $target',
    );
    final verified = await verifyNativeArchive(
      File(p.join(native.path, filename)),
      format: windows ? NativeArchiveFormat.zip : NativeArchiveFormat.tarGzip,
      expected: (
        size: record['size'] as int,
        sha256: record['sha256'] as String,
      ),
    );
    _require(
      verified.manifestSha256 == record['manifest_sha256'],
      'Native manifest identity differs: $target',
    );
    await validateNativePayload(
      verified.manifest,
      source,
      target: target,
      version: version as String,
      identity: identity,
    );
    targets[target] = {
      'url': Uri.https('github.com', '')
          .replace(
            pathSegments: [
              'GreatPika',
              'archway',
              'releases',
              'download',
              'v$version',
              filename,
            ],
          )
          .toString(),
      'size': verified.archiveSize,
      'sha256': verified.archiveSha256,
      'manifest_sha256': verified.manifestSha256,
    };
  }
  _require(sameJson(await sourceIdentity(source), identity), 'Source changed');
  await output.parent.create(recursive: true);
  final stage = await output.parent.createTemp('.archway-descriptor-');
  var published = false;
  try {
    final descriptor = {
      'schema_version': 1,
      'version': version,
      'source': identity,
      'targets': targets,
    };
    await File(p.join(stage.path, 'acquisition.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(descriptor)}\n',
    );
    publishDirectory(stage, output);
    published = true;
  } finally {
    if (!published) await stage.delete(recursive: true);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser();
    for (final name in ['source', 'native', 'expected-commit', 'output']) {
      parser.addOption(name, mandatory: true);
    }
    final args = parser.parse(arguments);
    _require(args.rest.isEmpty, 'Unexpected descriptor arguments');
    await generateDescriptor(
      source: Directory(args['source'] as String),
      native: Directory(args['native'] as String),
      output: Directory(args['output'] as String),
      expectedCommit: args['expected-commit'] as String,
    );
    stdout.writeln(
      'Prepared shared acquisition descriptor; no upload performed.',
    );
  } on Object catch (error) {
    stderr.writeln('Descriptor generation refused: $error');
    exitCode = 1;
  }
}
