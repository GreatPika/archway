// Pack only an admitted thin candidate; npm never runs lifecycle scripts here.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/publish_directory.dart';
import 'packed_inventory.dart';

void require(bool value, String message) {
  if (!value) throw FormatException(message);
}

Future<void> packNpm(Directory stage, Directory output) async {
  stage = stage.absolute;
  output = output.absolute;
  require(
    stage.resolveSymbolicLinksSync() == stage.path,
    'Expected canonical npm stage',
  );
  require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Packed output already exists',
  );
  final admitted = await admitNpmStage(stage);
  final receipt = admitted.receipt;
  final package = admitted.package;
  await output.parent.create(recursive: true);
  final temporary = await output.parent.createTemp('.archway-npm-pack-');
  var published = false;
  try {
    final environment = Map<String, String>.from(Platform.environment)
      ..removeWhere(
        (key, _) => [
          'node_options',
          'node_path',
          'node_auth_token',
          'npm_token',
        ].contains(key.toLowerCase()),
      );
    final result = await Process.run(
      'npm',
      [
        'pack',
        '--offline',
        '--ignore-scripts',
        '--json',
        '--pack-destination',
        temporary.path,
      ],
      workingDirectory: package.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: Platform.isWindows,
    );
    require(result.exitCode == 0, 'npm pack failed: ${result.stderr}');
    final packed = jsonDecode(result.stdout as String);
    require(
      packed is List && packed.length == 1 && packed.single is Map,
      'Invalid npm pack response',
    );
    final filename = (packed as List).single['filename'];
    require(
      filename is String &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.tgz$').hasMatch(filename),
      'Invalid npm tarball filename',
    );
    final archive = File(p.join(temporary.path, filename as String));
    late int size;
    late String hash;
    await withArchiveInput(archive, (input) async {
      size = input.size;
      hash = input.sha256;
      await verifyNpmArchiveInput(input, admitted.inventory);
      // Publish the admitted bytes themselves, rather than reopening npm's
      // original output after the owned snapshot has been verified.
      await input.file.rename(archive.path);
    }, temporaryParent: temporary);
    require(temporary.listSync().length == 1, 'Unexpected npm packed output');
    File(p.join(temporary.path, 'npm-packed.json')).writeAsStringSync(
      '${jsonEncode({'schema_version': 1, 'version': receipt['version'], 'source': receipt['source'], 'descriptor_sha256': receipt['descriptor_sha256'], 'registry_ready': receipt['registry_ready'], 'filename': filename, 'compressed_bytes': size, 'sha256': hash, 'stage_inventory_sha256': admitted.inventorySha256})}\n',
    );
    publishDirectory(temporary, output);
    published = true;
  } finally {
    if (!published) await temporary.delete(recursive: true);
  }
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('stage', mandatory: true)
    ..addOption('output', mandatory: true);
  try {
    final args = parser.parse(arguments);
    require(args.rest.isEmpty, 'Unexpected packing arguments');
    await packNpm(
      Directory(args['stage'] as String),
      Directory(args['output'] as String),
    );
  } on Object catch (error) {
    stderr.writeln('Npm packing failed: $error');
    exitCode = 1;
  }
}
