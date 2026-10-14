// Stage the small SDK wrapper from one clean source identity. Never publishes.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../release/archive_input.dart';
import '../release/installation_identity.dart';
import '../release/native_payload.dart';
import '../release/publish_directory.dart';
import '../release/strict_json.dart';
import '../validation/json_values.dart';

const pubStageSourceFiles = [
  'tool/pub/download.dart',
  'tool/pub/native_cache.dart',
  'tool/pub/launcher.dart',
  'tool/release/archive_extraction.dart',
  'tool/release/archive_input.dart',
  'tool/release/gzip_input.dart',
  'tool/release/tar_input.dart',
  'tool/release/zip_input.dart',
  'tool/release/native_manifest.dart',
  'tool/release/native_archive.dart',
  'tool/release/publish_directory.dart',
  'tool/release/strict_json.dart',
  'tool/validation/json_values.dart',
  'LICENSE',
  'CHANGELOG.md',
];
const pubStageDependencies = {
  'archive': '4.5.2',
  'crypto': '3.0.7',
  'ffi': '2.2.0',
  'path': '1.9.1',
  'posix': '6.5.2',
  'tar': '2.0.3',
  'unorm_dart': '0.3.2',
};
void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

Future<void> stagePub({
  required Directory source,
  required File descriptor,
  required Directory output,
  required String expectedCommit,
  bool registryReady = false,
}) async {
  source = source.absolute;
  output = output.absolute;
  _require(
    source.resolveSymbolicLinksSync() == source.path,
    'Expected canonical source directory',
  );
  _require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Pub stage output already exists',
  );
  final identity = await sourceIdentity(source);
  _require(identity['commit'] == expectedCommit, 'Source commit differs');
  final metadata = await nativePubspec(source);
  final version = metadata['version'];
  _require(
    metadata['name'] == 'archway' &&
        version is String &&
        Version.parse(version).toString() == version &&
        metadata['repository'] == 'https://github.com/GreatPika/archway',
    'Invalid canonical package identity',
  );
  final dependencies = {
    if (metadata['dependencies'] is Map) ...metadata['dependencies'] as Map,
    if (metadata['dev_dependencies'] is Map)
      ...metadata['dev_dependencies'] as Map,
  };
  _require(
    pubStageDependencies.entries.every(
      (entry) => dependencies[entry.key] == entry.value,
    ),
    'Source runtime dependency pins differ',
  );
  final descriptorBytes = await withArchiveInput(
    descriptor,
    (input) => input.file.readAsBytes(),
    maxBytes: maxArchiveJsonBytes,
  );
  final acquisition = decodeEvidenceJson(utf8.decode(descriptorBytes));
  _require(
    acquisition is Map<String, Object?> &&
        acquisition.length == 4 &&
        acquisition['schema_version'] is int &&
        acquisition['schema_version'] == 1 &&
        acquisition['version'] == version &&
        sameJson(acquisition['source'], identity),
    'Descriptor source or version differs',
  );
  final targets = (acquisition as Map)['targets'];
  _require(
    targets is Map &&
        targets.length == nativeTargets.length &&
        nativeTargets.keys.every(targets.containsKey),
    'Descriptor targets differ',
  );
  for (final target in nativeTargets.keys) {
    final selected = (targets as Map)[target];
    final suffix = target == 'windows-x64' ? '.zip' : '.tar.gz';
    final url = Uri.https('github.com', '')
        .replace(
          pathSegments: [
            'GreatPika',
            'archway',
            'releases',
            'download',
            'v$version',
            'archway-$version-$target$suffix',
          ],
        )
        .toString();
    bool digest(Object? value) =>
        value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
    _require(
      selected is Map &&
          selected.length == 4 &&
          selected['url'] == url &&
          selected['size'] is int &&
          selected['size'] > 0 &&
          selected['size'] <= maxArchiveBytes &&
          digest(selected['sha256']) &&
          digest(selected['manifest_sha256']),
      'Invalid pinned descriptor target: $target',
    );
  }
  final gitEnvironment = Map<String, String>.from(Platform.environment)
    ..removeWhere((key, _) => key.toUpperCase().startsWith('GIT_'));
  final tracked = await Process.run(
    'git',
    [
      '-C',
      source.path,
      'ls-files',
      '--error-unmatch',
      '--',
      ...pubStageSourceFiles,
    ],
    environment: gitEnvironment,
    includeParentEnvironment: false,
  );
  _require(tracked.exitCode == 0, 'Pub runtime closure must be tracked source');
  await output.parent.create(recursive: true);
  final temporary = await output.parent.createTemp('.archway-pub-stage-');
  var published = false;
  try {
    final package = Directory(p.join(temporary.path, 'package'))..createSync();
    final files = <String, Object?>{};
    void write(String name, List<int> bytes) {
      final file = File(p.join(package.path, name));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      files[name] = {
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      };
    }

    for (final name in pubStageSourceFiles) {
      await withArchiveInput(File(p.join(source.path, name)), (input) async {
        write(name, await input.file.readAsBytes());
      }, maxBytes: maxArchiveJsonBytes);
    }
    // JSON is YAML; exact dependency pins form the complete runtime closure.
    write(
      'pubspec.yaml',
      utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert({
          'name': 'archway',
          'version': version,
          'description': 'Thin Dart launcher for the pinned Archway native CLI.',
          'repository': 'https://github.com/GreatPika/archway',
          if (!registryReady) 'publish_to': 'none',
          'environment': {'sdk': '>=3.13.3 <4.0.0'},
          'dependencies': pubStageDependencies,
        })}\n',
      ),
    );
    write(
      'bin/archway.dart',
      utf8.encode('''
import 'dart:convert';
import 'dart:io';
import '../tool/pub/launcher.dart';
Future<void> main(List<String> arguments) async {
  final descriptor = jsonDecode(${jsonEncode(jsonEncode(acquisition))}) as Map<String, Object?>;
  exitCode = await launchPubNative(descriptor, arguments);
}
'''),
    );
    write(
      'README.md',
      utf8.encode('''# Archway $version

Install: `dart pub global activate --no-executables archway $version`

Run: `dart pub global run archway:archway <args>`

First invocation downloads the pinned native payload for this host. Offline use
requires a prepared snapshot under the same SDK and a verified native cache.
After changing SDKs, run `dart pub global run archway:archway --version` once
before capturing JSON: SDK snapshot preparation can print dependency progress.
There is no setup command or generated command alias.
'''),
    );
    _require(
      sameJson(await sourceIdentity(source), identity),
      'Source changed during pub staging',
    );
    File(p.join(temporary.path, 'pub-stage.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'schema_version': 1, 'version': version, 'source': identity, 'descriptor_sha256': sha256.convert(descriptorBytes).toString(), 'registry_ready': registryReady, 'files': files})}\n',
    );
    publishDirectory(temporary, output);
    published = true;
  } finally {
    if (!published) await temporary.delete(recursive: true);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser()..addFlag('registry-ready', negatable: false);
    for (final name in ['source', 'descriptor', 'expected-commit', 'output']) {
      parser.addOption(name, mandatory: true);
    }
    final args = parser.parse(arguments);
    _require(args.rest.isEmpty, 'Unexpected pub stage arguments');
    await stagePub(
      source: Directory(args['source'] as String),
      descriptor: File(args['descriptor'] as String),
      output: Directory(args['output'] as String),
      expectedCommit: args['expected-commit'] as String,
      registryReady: args['registry-ready'] as bool,
    );
    stdout.writeln('Prepared pub wrapper; no publication performed.');
  } catch (error) {
    stderr.writeln('Pub staging refused: $error');
    exitCode = 1;
  }
}
