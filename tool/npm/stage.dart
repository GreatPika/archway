// Developer staging only: prepare locked wrapper dependencies offline, never publish.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../release/archive_input.dart';
import '../release/archive_extraction.dart' show setArchiveMode;
import '../release/installation_identity.dart';
import '../release/native_payload.dart';
import '../release/publish_directory.dart';
import '../release/strict_json.dart';
import '../validation/json_values.dart';

const _runtime = ['archway', 'archive', 'cache', 'download', 'inventory'];
void require(bool ok, String message) {
  if (!ok) throw FormatException(message);
}

Future<void> stageNpm(
  Directory source,
  File descriptor,
  Directory output,
  String expectedCommit, {
  bool registryReady = false,
}) async {
  source = source.absolute;
  output = output.absolute;
  require(
    source.resolveSymbolicLinksSync() == source.path,
    'Expected canonical source',
  );
  require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Npm stage output already exists',
  );
  final identity = await sourceIdentity(source);
  require(identity['commit'] == expectedCommit, 'Source commit differs');
  final metadata = await nativePubspec(source);
  final version = metadata['version'];
  require(
    metadata['name'] == 'archway' &&
        version is String &&
        Version.parse(version).toString() == version &&
        metadata['repository'] == 'https://github.com/GreatPika/archway',
    'Invalid canonical package identity',
  );
  final descriptorBytes = await withArchiveInput(
    descriptor,
    (input) => input.file.readAsBytes(),
    maxBytes: maxArchiveJsonBytes,
  );
  final acquisition = decodeEvidenceJson(utf8.decode(descriptorBytes));
  require(
    acquisition is Map<String, Object?> &&
        acquisition.length == 4 &&
        acquisition['schema_version'] == 1 &&
        acquisition['version'] == version &&
        sameJson(acquisition['source'], identity),
    'Descriptor source or version differs',
  );
  final targets = (acquisition as Map)['targets'];
  require(
    targets is Map &&
        targets.length == 3 &&
        nativeTargets.keys.every(targets.containsKey),
    'Descriptor targets differ',
  );
  for (final target in nativeTargets.keys) {
    final pin = (targets as Map)[target];
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
    require(
      pin is Map &&
          pin.length == 4 &&
          pin['url'] == url &&
          pin['size'] is int &&
          pin['size'] > 0 &&
          pin['size'] <= maxArchiveBytes &&
          digest(pin['sha256']) &&
          digest(pin['manifest_sha256']),
      'Invalid pinned descriptor target: $target',
    );
  }
  final paths = [
    'LICENSE',
    'CHANGELOG.md',
    'tool/npm/README.md',
    'tool/npm/package.json',
    'tool/npm/package-lock.json',
    for (final name in _runtime) 'tool/npm/$name.cjs',
  ];
  final tracked = await Process.run(
    'git',
    ['-C', source.path, 'ls-files', '--error-unmatch', '--', ...paths],
    environment: Map<String, String>.from(Platform.environment)
      ..removeWhere((key, _) => key.toUpperCase().startsWith('GIT_')),
    includeParentEnvironment: false,
  );
  require(tracked.exitCode == 0, 'Npm runtime closure must be tracked source');
  final tooling = await readNativeJson(
    File(p.join(source.path, 'tool/npm/package.json')),
  );
  final lock = await readNativeJson(
    File(p.join(source.path, 'tool/npm/package-lock.json')),
  );
  final packageValue = lock['packages'];
  require(packageValue is Map, 'Invalid wrapper lock package inventory');
  final packages = packageValue as Map;
  final dependencies = tooling['dependencies'];
  require(
    tooling['private'] == true &&
        dependencies is Map &&
        dependencies.isNotEmpty &&
        lock['lockfileVersion'] == 3 &&
        sameJson(packages['']['dependencies'], dependencies),
    'Invalid locked wrapper dependencies',
  );
  final ownedPackages = <String>[];
  for (final name in packages.keys.where((name) => name != '')) {
    final record = packages[name];
    require(
      name is String &&
          RegExp(r'^node_modules/(?:@[a-z0-9._-]+/)?[a-z0-9._-]+$')
              .hasMatch(name) &&
          record is Map &&
          record['version'] is String &&
          record['integrity'] is String &&
          (record['integrity'] as String).startsWith('sha512-') &&
          record['resolved'] is String &&
          Uri.parse(record['resolved']).host == 'registry.npmjs.org' &&
          Uri.parse(record['resolved']).scheme == 'https',
      'Invalid dependency lock identity',
    );
    ownedPackages.add(name);
  }
  await output.parent.create(recursive: true);
  final temporary = await output.parent.createTemp('.archway-npm-stage-');
  Directory? ownedCandidate;
  Object? failure;
  StackTrace? failureStack;
  var published = false;
  try {
    final candidate = await output.parent.createTemp('.archway-npm-candidate-');
    ownedCandidate = candidate;
    final preparation = Directory(p.join(temporary.path, 'prepare'))
      ..createSync();
    for (final name in ['package.json', 'package-lock.json'])
      File(p.join(source.path, 'tool/npm', name))
          .copySync(p.join(preparation.path, name));
    final environment = Map<String, String>.from(Platform.environment);
    final cache = environment['npm_config_cache'];
    environment.removeWhere(
      (key, _) =>
          key.toLowerCase().startsWith('npm_config_') ||
          [
            'node_options',
            'node_path',
            'node_auth_token',
            'npm_token',
          ].contains(key.toLowerCase()),
    );
    if (cache != null) environment['npm_config_cache'] = cache;
    for (final name in ['userconfig', 'globalconfig']) {
      final file = File(p.join(temporary.path, '$name.npmrc'))
        ..writeAsStringSync('');
      environment['npm_config_$name'] = file.path;
    }
    final prepared = await Process.run(
      'npm',
      [
        'ci',
        '--offline',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
        '--registry=https://registry.npmjs.org',
      ],
      workingDirectory: preparation.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: Platform.isWindows,
    );
    require(
      prepared.exitCode == 0,
      'Offline locked npm dependency preparation failed: ${prepared.stderr}',
    );
    final package = Directory(p.join(candidate.path, 'package'))
      ..createSync(recursive: true);
    final files = <String, Object?>{};
    void write(String name, List<int> bytes, {int mode = 0x1a4}) {
      final file = File(p.joinAll([package.path, ...name.split('/')]))
        ..parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      setArchiveMode(file.path, mode);
      files[name] = {
        'size': bytes.length,
        'mode': mode,
        'sha256': sha256.convert(bytes).toString(),
      };
    }

    Future<void> copy(String relative, String target, {int mode = 0x1a4}) =>
        withArchiveInput(
          File(p.join(source.path, relative)),
          (input) async =>
              write(target, await input.file.readAsBytes(), mode: mode),
        );
    for (final name in _runtime)
      await copy(
        'tool/npm/$name.cjs',
        'bin/$name.cjs',
        mode: name == 'archway' ? 0x1ed : 0x1a4,
      );
    for (final name in ['LICENSE', 'CHANGELOG.md']) await copy(name, name);
    await copy('tool/npm/README.md', 'README.md');
    write('acquisition.json', descriptorBytes);
    write(
      'package.json',
      utf8.encode(
        '${jsonEncode({
          'name': 'archway-architecture-cli',
          'version': version,
          'private': !registryReady,
          'description': 'Architecture policy CLI for TypeScript and Dart projects.',
          'license': 'MIT',
          'repository': 'https://github.com/GreatPika/archway',
          'bin': {'archway': 'bin/archway.cjs'},
          'dependencies': dependencies,
          'bundledDependencies': (dependencies as Map).keys.toList(),
        })}\n',
      ),
    );
    final observedPackages = <String>{};
    final modules = Directory(p.join(preparation.path, 'node_modules'));
    for (final entity in modules.listSync(followLinks: false)) {
      if (p.basename(entity.path) == '.package-lock.json' && entity is File)
        continue;
      require(entity is Directory, 'Unexpected npm dependency root entry');
      if (p.basename(entity.path).startsWith('@')) {
        for (final child in (entity as Directory).listSync(
          followLinks: false,
        )) {
          require(child is Directory, 'Unexpected scoped dependency entry');
          observedPackages.add(
            p
                .relative(child.path, from: preparation.path)
                .replaceAll('\\', '/'),
          );
        }
      } else {
        observedPackages.add(
          p.relative(entity.path, from: preparation.path).replaceAll('\\', '/'),
        );
      }
    }
    require(
      observedPackages.length == ownedPackages.length &&
          observedPackages.containsAll(ownedPackages),
      'Prepared npm dependency set differs from lock',
    );
    for (final name in ownedPackages) {
      final directory = Directory(p.join(preparation.path, name));
      final actual = await readNativeJson(
        File(p.join(directory.path, 'package.json')),
      );
      require(
        actual['version'] == packages[name]['version'],
        'Prepared npm dependency version differs',
      );
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        require(
          entity is File || entity is Directory,
          'Nonordinary prepared npm dependency',
        );
        require(
          entity.resolveSymbolicLinksSync() == entity.path,
          'Aliased prepared npm dependency',
        );
        if (entity is File) {
          final relative = p
              .relative(entity.path, from: preparation.path)
              .replaceAll('\\', '/');
          await withArchiveInput(
            entity,
            (input) async => write(relative, await input.file.readAsBytes()),
          );
        }
      }
    }
    require(
      sameJson(await sourceIdentity(source), identity),
      'Source changed during npm staging',
    );
    File(p.join(candidate.path, 'npm-stage.json')).writeAsStringSync(
      '${jsonEncode({'schema_version': 1, 'version': version, 'source': identity, 'descriptor_sha256': sha256.convert(descriptorBytes).toString(), 'registry_ready': registryReady, 'files': files})}\n',
    );
    publishDirectory(package.parent, output);
    published = true;
  } on Object catch (error, stack) {
    failure = error;
    failureStack = stack;
  } finally {
    // Attempt every owned cleanup, preserving the original staging failure.
    for (final directory in [
      temporary,
      if (!published && ownedCandidate != null) ownedCandidate,
    ]) {
      try {
        await directory.delete(recursive: true);
      } on Object catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
  }
  if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  require(published, 'Npm stage was not published');
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('source', mandatory: true)
    ..addOption('descriptor', mandatory: true)
    ..addOption('output', mandatory: true)
    ..addOption('expected-commit', mandatory: true)
    ..addFlag('registry-ready', negatable: false);
  try {
    final args = parser.parse(arguments);
    require(args.rest.isEmpty, 'Unexpected staging arguments');
    await stageNpm(
      Directory(args['source'] as String),
      File(args['descriptor'] as String),
      Directory(args['output'] as String),
      args['expected-commit'] as String,
      registryReady: args['registry-ready'] as bool,
    );
  } on Object catch (error) {
    stderr.writeln('Npm staging failed: $error');
    exitCode = 1;
  }
}
