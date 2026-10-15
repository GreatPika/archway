// Full source tests from tracked bytes, verified archive assets and prepared fixtures.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../release/installation_identity.dart';
import 'native_acceptance.dart';
import 'native_source_report.dart';
import 'source_npm_preparation.dart';

import 'dart:io';

import 'package:path/path.dart' as p;

Map<String, String> sourceTestEnvironment(
  Map<String, String> environment,
  Directory parent,
) {
  final temporary = Directory(p.join(parent.path, 'test-tmp'))..createSync();
  final canonical = temporary.resolveSymbolicLinksSync();
  return {...environment}
    ..remove('ARCHWAY_TEST_PYTHON')
    ..addAll({
      for (final key in ['TMPDIR', 'TMP', 'TEMP', 'RUNNER_TEMP'])
        key: canonical,
    });
}

// The complete source inventory has a 25-minute aggregate CI wall budget.
// Native process suites and source dependency preparation retain 600 seconds.
const sourceSuiteTimeout = Duration(seconds: 1500);

typedef SourceExecute = Future<Map<String, Object?>> Function(
  String name,
  List<String> command,
  String cwd,
  Map<String, String> environment,
  Directory output, {
  required Duration timeout,
});

String _sha(File file) => sha256.convert(file.readAsBytesSync()).toString();

File _ordinary(Directory root, String relative) {
  final parts = relative.split('/');
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
      p.isAbsolute(relative)) {
    throw FormatException('Noncanonical source file: $relative');
  }
  var path = root.path;
  for (var i = 0; i < parts.length; i++) {
    path = p.join(path, parts[i]);
    final expected = i == parts.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (FileSystemEntity.typeSync(path, followLinks: false) != expected) {
      throw FormatException(
        'Source snapshot requires an ordinary tracked/asset file: $relative',
      );
    }
  }
  return File(path);
}

Future<List<String>> _tracked(Directory repo) async {
  final args = ['-C', repo.path, 'ls-files', '-z'];
  final child = await Process.start('git', args);
  final stdout = child.stdout.fold<List<int>>(
    [],
    (bytes, chunk) => bytes..addAll(chunk),
  );
  final stderr = child.stderr.transform(utf8.decoder).join();
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final results = await Future.wait<Object>([exit, stdout, stderr])
        .timeout(const Duration(seconds: 30));
    if (results[0] != 0)
      throw ProcessException(
        'git',
        args,
        results[2] as String,
        results[0] as int,
      );
    return utf8
        .decode(results[1] as List<int>)
        .split('\u0000')
        .where((name) => name.isNotEmpty)
        .toList()
      ..sort();
  } finally {
    if (!exited) {
      child.kill(ProcessSignal.sigkill);
      await exit.timeout(const Duration(seconds: 5));
    }
  }
}

Future<Map<String, Object?>> runSourceTests(
  Directory repository,
  String executable,
  Map<String, String> fixtures,
  Map<String, String> environment,
  Directory output, {
  SourceExecute execute = executeSuite,
}) async {
  final identity = await sourceIdentity(repository);
  final target = p.basename(p.dirname(executable));
  const libraries = {
    'linux-x64': 'libarchway_io.so',
    'macos-arm64': 'libarchway_io.dylib',
    'windows-x64': 'archway_io.dll',
  };
  if (!libraries.containsKey(target))
    throw FormatException('Unsupported source target: $target');
  final bundle = Directory(p.dirname(p.dirname(p.dirname(executable))));
  final dart = p.join(
    fixtures['dart_sdk']!,
    'bin',
    target == 'windows-x64' ? 'dart.exe' : 'dart',
  );
  for (final fixture in ['git_fixture', 'flutter_fixture']) {
    for (final name in [
      'pubspec.yaml',
      'pubspec.lock',
      '.dart_tool/package_config.json',
    ]) {
      if (!File(p.join(fixtures[fixture]!, name)).existsSync()) {
        throw FormatException(
          'Missing mandatory source fixture: $fixture/$name',
        );
      }
    }
  }
  final tracked = await _tracked(repository);
  final expectedTests = tracked
      .where((name) => name.startsWith('test/') && name.endsWith('_test.dart'))
      .toSet();
  final temporary = Directory.systemTemp.createTempSync(
    'archway-source-suite-',
  );
  try {
    final env = sourceTestEnvironment({
      ...environment,
      'ARCHWAY_PUB_GIT_FIXTURE': fixtures['git_fixture']!,
      'ARCHWAY_FLUTTER_FIXTURE': fixtures['flutter_fixture']!,
    }, temporary);
    final source = Directory(
      p.join(temporary.resolveSymbolicLinksSync(), 'source'),
    )..createSync();
    final snapshot = <String, String>{};
    for (final name in tracked) {
      final original = _ordinary(repository, name);
      final destination = File(p.join(source.path, name));
      destination.parent.createSync(recursive: true);
      final digest = _sha(original);
      original.copySync(destination.path);
      if (_sha(destination) != digest)
        throw const FormatException(
          'Source snapshot bytes changed during copying',
        );
      snapshot[name] = digest;
    }
    final inventory = File(p.join(output.path, 'source-files.json'))
      ..createSync(exclusive: true);
    inventory.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
      flush: true,
    );
    final assets = <String, String>{};
    void copyAsset(String relative) {
      final original = _ordinary(bundle, relative);
      final destination = File(p.join(source.path, relative));
      if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FormatException(
          'Archive asset collides with tracked source: $relative',
        );
      }
      final digest = _sha(original);
      destination.parent.createSync(recursive: true);
      original.copySync(destination.path);
      if (_sha(destination) != digest)
        throw const FormatException(
          'Source-suite asset differs from verified archive',
        );
      assets[relative] = digest;
    }

    copyAsset('native/$target/${libraries[target]}');
    const vendor = 'assets/typescript/vendor';
    final vendorRoot = Directory(p.join(bundle.path, vendor));
    if (FileSystemEntity.typeSync(vendorRoot.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(
              p.join(source.path, vendor),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      throw const FormatException(
        'Archive vendor is missing, linked or collides with tracked source',
      );
    }
    Directory(p.join(source.path, vendor)).createSync(recursive: true);
    for (final entry in vendorRoot.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p
          .relative(entry.path, from: bundle.path)
          .split(p.separator)
          .join('/');
      if (entry is Directory) {
        Directory(p.join(source.path, relative)).createSync(recursive: true);
      } else {
        copyAsset(relative);
      }
    }
    final preparation = await execute(
      'source-pub-get',
      [dart, '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
      source.path,
      env,
      output,
      timeout: suiteTimeout,
    );
    if (_sha(_ordinary(source, 'pubspec.lock')) != snapshot['pubspec.lock']) {
      throw const FormatException(
        'Source dependency preparation changed the exact lock',
      );
    }
    final node = env['ARCHWAY_TEST_NODE'];
    if (node == null) {
      throw const FormatException(
        'Source npm preparation requires admitted Node',
      );
    }
    final npmPreparation = await execute(
      'source-npm-ci',
      sourceNpmCommand(node, source.path, p.context),
      source.path,
      env,
      output,
      timeout: suiteTimeout,
    );
    for (final name in [
      'tool/npm/package.json',
      'tool/npm/package-lock.json',
    ]) {
      if (_sha(_ordinary(source, name)) != snapshot[name]) {
        throw const FormatException(
          'Source npm preparation changed tracked inputs',
        );
      }
    }
    // Keep the same bounded suite parallelism on three- and four-core hosts.
    final execution = await execute(
      'source-tests',
      [dart, 'test', '--reporter=json', '--concurrency=2'],
      source.path,
      env,
      output,
      timeout: sourceSuiteTimeout,
    );
    final events = File(p.join(output.path, execution['stdout'] as String))
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map<String, dynamic>);
    final summary = summarizeTests(events, expectedTests, target);
    for (final entry in {...snapshot, ...assets}.entries) {
      if (_sha(_ordinary(source, entry.key)) != entry.value) {
        throw FormatException(
          'Source tests changed snapshot/installation bytes: ${entry.key}',
        );
      }
    }
    if (jsonEncode(await sourceIdentity(repository)) != jsonEncode(identity)) {
      throw const FormatException(
        'Original tracked sources changed during source tests',
      );
    }
    return {
      'source': identity,
      'snapshot_root': source.path,
      'dart': dart,
      'target': target,
      'snapshot_manifest': p.basename(inventory.path),
      'snapshot_manifest_sha256': _sha(inventory),
      'assets': assets,
      'preparation': preparation,
      'npm_preparation': npmPreparation,
      'execution': execution,
      'tests': summary,
    };
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
