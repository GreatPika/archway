import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../tool/release/installation_identity.dart';
import '../tool/pub/stage_inventory.dart';
import 'support/pub_stage_fixture.dart';

void main() {
  late Directory root, source;
  late File descriptor;
  late Map<String, Object> identity;
  setUp(() async {
    final fixture = await preparePubStageFixture();
    root = fixture.root;
    source = fixture.source;
    descriptor = fixture.descriptor;
    identity = fixture.identity;
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<ProcessResult> stage(String output, {bool registry = false}) =>
      Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/pub/stage.dart',
        '--source',
        source.path,
        '--descriptor',
        descriptor.path,
        '--expected-commit',
        identity['commit'] as String,
        '--output',
        p.join(root.path, output),
        if (registry) '--registry-ready',
      ]);
  test('stage has a complete thin runtime closure and private publication metadata', () async {
    final result = await stage('private');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final package = Directory(p.join(root.path, 'private', 'package'));
    final names = package
        .listSync(recursive: true)
        .whereType<File>()
        .map(
          (f) => p
              .relative(f.path, from: package.path)
              .split(p.separator)
              .join('/'),
        )
        .toSet();
    expect(names, {
      ...pubRuntimeFixtureFiles,
      'bin/archway.dart',
      'pubspec.yaml',
      'LICENSE',
      'CHANGELOG.md',
      'README.md',
    });
    final metadata = loadYaml(
      File(p.join(package.path, 'pubspec.yaml')).readAsStringSync(),
    ) as YamlMap;
    expect(metadata['publish_to'], 'none');
    expect(metadata['version'], '0.2.0');
    expect(metadata['executables'], isNull);
    expect((metadata['dependencies'] as YamlMap).cast<String, String>(), {
      'archive': '4.5.2',
      'crypto': '3.0.7',
      'ffi': '2.2.0',
      'path': '1.9.1',
      'posix': '6.5.2',
      'tar': '2.0.3',
      'unorm_dart': '0.3.2',
    });
    final prepared = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(
      prepared.exitCode,
      0,
      reason: '${prepared.stdout}\n${prepared.stderr}',
    );
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      'bin/archway.dart',
      '-o',
      p.join(root.path, 'launcher.dill'),
    ], workingDirectory: package.path);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
  });
  test(
    'registry intent is applied before complete stage inventory hashing',
    () async {
      final result = await stage('registry', registry: true);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final output = Directory(p.join(root.path, 'registry'));
      final inspected = await inspectPubStage(
        output,
        identity,
        registryReady: true,
      );
      expect(inspected.files.files.length, pubRuntimeFixtureFiles.length + 5);
      await expectLater(
        inspectPubStage(output, identity, registryReady: false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('intent differs'),
          ),
        ),
      );
      final receipt = jsonDecode(
        File(p.join(output.path, 'pub-stage.json')).readAsStringSync(),
      ) as Map;
      expect(receipt['registry_ready'], isTrue);
      expect(receipt['source'], identity);
      expect(
        receipt['descriptor_sha256'],
        sha256.convert(descriptor.readAsBytesSync()).toString(),
      );
      final files = receipt['files'] as Map;
      final package = Directory(p.join(output.path, 'package'));
      expect(files.keys.toSet(), {
        ...pubRuntimeFixtureFiles,
        'bin/archway.dart',
        'pubspec.yaml',
        'LICENSE',
        'CHANGELOG.md',
        'README.md',
      });
      for (final name in files.keys.cast<String>()) {
        final bytes = File(p.join(package.path, name)).readAsBytesSync();
        expect(files[name], {
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        }, reason: name);
      }
      expect(
        (loadYaml(
          File(p.join(package.path, 'pubspec.yaml')).readAsStringSync(),
        ) as YamlMap).containsKey('publish_to'),
        isFalse,
      );
      final before = File(p.join(output.path, 'pub-stage.json'))
          .readAsBytesSync();
      final duplicate = await stage('registry');
      expect(duplicate.exitCode, 1);
      expect(duplicate.stderr, contains('Pub stage output already exists'));
      expect(
        File(p.join(output.path, 'pub-stage.json')).readAsBytesSync(),
        before,
      );
    },
  );
  test('descriptor binding failures publish no package', () async {
    final original = descriptor.readAsStringSync();
    final cases = <String, void Function(Map)>{
      'Descriptor source or version differs': (value) =>
          value['version'] = '0.2.1',
      'Descriptor targets differ': (value) =>
          (value['targets'] as Map).remove('windows-x64'),
      'Invalid pinned descriptor target': (value) =>
          value['targets']['linux-x64']['url'] =
              'https://example.invalid/archive',
    };
    for (final entry in cases.entries) {
      final value = jsonDecode(original) as Map;
      entry.value(value);
      descriptor.writeAsStringSync(jsonEncode(value));
      final result = await stage('refused');
      expect(result.exitCode, 1);
      expect(result.stderr, contains(entry.key));
      expect(Directory(p.join(root.path, 'refused')).existsSync(), isFalse);
    }
  });
  test(
    'untracked wrapper bytes cannot inherit a clean source identity',
    () async {
      expect(
        Process.runSync('git', [
          '-C',
          source.path,
          'rm',
          '--cached',
          'tool/pub/launcher.dart',
        ]).exitCode,
        0,
      );
      expect(
        Process.runSync('git', [
          '-C',
          source.path,
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'commit',
          '-qm',
          'omit launcher',
        ]).exitCode,
        0,
      );
      identity = await sourceIdentity(source);
      final value = jsonDecode(descriptor.readAsStringSync()) as Map;
      value['source'] = identity;
      descriptor.writeAsStringSync(jsonEncode(value));
      final result = await stage('untracked');
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Pub runtime closure must be tracked source'),
      );
      expect(Directory(p.join(root.path, 'untracked')).existsSync(), isFalse);
    },
  );
  test('stage consumer binds source and complete package bytes', () async {
    final result = await stage('inspected');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final output = Directory(p.join(root.path, 'inspected'));
    final inspected = await inspectPubStage(
      output,
      identity,
      registryReady: false,
    );
    expect(
      inspected.sha256,
      sha256
          .convert(
            File(p.join(output.path, 'pub-stage.json')).readAsBytesSync(),
          )
          .toString(),
    );
    await expectLater(
      inspectPubStage(output, {
        ...identity,
        'commit': '0' * 40,
      }, registryReady: false),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'diagnostic',
          contains('identity or intent differs'),
        ),
      ),
    );
    final launcher = File(p.join(output.path, 'package/bin/archway.dart'));
    final bytes = launcher.readAsBytesSync()..[0] ^= 1;
    launcher.writeAsBytesSync(bytes);
    await expectLater(
      inspectPubStage(output, identity, registryReady: false),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'diagnostic',
          contains('Installation identity differs'),
        ),
      ),
    );
    expect(launcher.readAsBytesSync(), bytes);
  });
}
