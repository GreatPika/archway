import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/installation_identity.dart';
import 'support/native_release_fixture.dart';

void main() {
  late Directory root, source, native;
  late Map<String, Object> identity;
  late Map<String, Object?> receipt;
  final script = p.absolute('tool/release/generate_descriptor.dart');
  const targets = ['linux-x64', 'macos-arm64', 'windows-x64'];
  void writeJson(File file, Object value) =>
      file.writeAsStringSync('${jsonEncode(value)}\n');
  void git(List<String> args) {
    final result = Process.runSync('git', ['-C', source.path, ...args]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
  }

  Future<ProcessResult> generate([String output = 'descriptor']) =>
      Process.run(Platform.resolvedExecutable, [
        script,
        '--source',
        source.path,
        '--native',
        native.path,
        '--expected-commit',
        identity['commit']! as String,
        '--output',
        p.join(root.path, output),
      ]);
  setUp(() async {
    final fixture = await prepareNativeReleaseFixture();
    root = fixture.root;
    source = fixture.source;
    identity = fixture.identity;
    final built = await buildNativeFixture(fixture, 'native café');
    expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
    Directory(p.join(source.path, 'assets/typescript/vendor'))
        .deleteSync(recursive: true);
    native = Directory(p.join(root.path, 'native café'));
    receipt = Map<String, Object?>.from(
      jsonDecode(
        File(p.join(native.path, 'native-packaging.json')).readAsStringSync(),
      ) as Map,
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('native bytes produce reproducible shared descriptor without wrapper inputs', () async {
    final first = await generate();
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    final file = File(p.join(root.path, 'descriptor/acquisition.json'));
    final result = jsonDecode(file.readAsStringSync()) as Map;
    final expectedTargets = <String, Object?>{};
    for (final target in targets) {
      final record = (receipt['native_bundles'] as Map)[target] as Map;
      expectedTargets[target] = {
        'url':
            'https://github.com/GreatPika/archway/releases/download/v1.2.3/${record['filename']}',
        'size': record['size'],
        'sha256': record['sha256'],
        'manifest_sha256': record['manifest_sha256'],
      };
    }
    expect(result, {
      'schema_version': 1,
      'version': '1.2.3',
      'source': identity,
      'targets': expectedTargets,
    });
    expect((await generate('second')).exitCode, 0);
    expect(
      File(p.join(root.path, 'second/acquisition.json')).readAsBytesSync(),
      file.readAsBytesSync(),
    );
    expect(
      Directory(p.join(root.path, 'descriptor'))
          .listSync()
          .map((e) => p.basename(e.path)),
      ['acquisition.json'],
    );
  });
  test(
    'rejects producer identity and byte pin changes before publication',
    () async {
      final original = jsonEncode(receipt);
      final cases = <(String, void Function(Map), String)>[
        (
          'source',
          (r) => r['source'] = {...identity, 'commit': 'b' * 40},
          'Native producer identity differs',
        ),
        (
          'version',
          (r) => r['version'] = '0.3.0',
          'Native producer identity differs',
        ),
        (
          'missing target',
          (r) => (r['native_bundles'] as Map).remove('macos-arm64'),
          'Native producer target set differs',
        ),
        (
          'extra target',
          (r) => r['native_bundles']['linux-arm64'] =
              r['native_bundles']['linux-x64'],
          'Native producer target set differs',
        ),
        (
          'filename',
          (r) => r['native_bundles']['linux-x64']['filename'] = '../elsewhere',
          'Invalid native producer archive',
        ),
        (
          'size',
          (r) => r['native_bundles']['linux-x64']['size'] += 1,
          'Archive input differs from pinned identity',
        ),
        (
          'digest',
          (r) => r['native_bundles']['linux-x64']['sha256'] = '0' * 64,
          'Archive input differs from pinned identity',
        ),
        (
          'manifest',
          (r) => r['native_bundles']['linux-x64']['manifest_sha256'] = '0' * 64,
          'Native manifest identity differs',
        ),
      ];
      for (final (name, mutate, diagnostic) in cases) {
        final changed = jsonDecode(original) as Map;
        mutate(changed);
        writeJson(File(p.join(native.path, 'native-packaging.json')), changed);
        final result = await generate();
        expect(result.exitCode, isNot(0), reason: name);
        expect(result.stderr, contains(diagnostic), reason: name);
        expect(
          Directory(p.join(root.path, 'descriptor')).existsSync(),
          isFalse,
          reason: name,
        );
      }
    },
    // Eight real CLI invocations each compile the release tooling.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('refuses changed archive bytes and preserves existing output', () async {
    final input = File(p.join(native.path, 'archway-1.2.3-linux-x64.tar.gz'));
    final bytes = input.readAsBytesSync();
    final changed = List<int>.of(bytes)..[10] ^= 1;
    input.writeAsBytesSync(changed);
    final rejected = await generate();
    expect(rejected.exitCode, isNot(0));
    expect(
      rejected.stderr,
      contains('Archive input differs from pinned identity'),
    );
    expect(Directory(p.join(root.path, 'descriptor')).existsSync(), isFalse);
    input.writeAsBytesSync(bytes);
    final output = Directory(p.join(root.path, 'descriptor'))..createSync();
    final sentinel = File(p.join(output.path, 'keep'))
      ..writeAsStringSync('original');
    final existing = await generate();
    expect(existing.exitCode, isNot(0));
    expect(existing.stderr, contains('Descriptor output already exists'));
    expect(sentinel.readAsStringSync(), 'original');
    expect(output.listSync().length, 1);
  });
  test(
    'refuses untrusted repository metadata before consuming artifacts',
    () async {
      final metadata = File(p.join(source.path, 'pubspec.yaml'));
      metadata.writeAsStringSync(
        metadata.readAsStringSync().replaceFirst(
          'https://github.com/GreatPika/archway',
          'https://github.com/elsewhere/archway',
        ),
      );
      git(['add', 'pubspec.yaml']);
      git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-qm',
        'Changed repository',
      ]);
      identity = await sourceIdentity(source);
      final result = await generate();
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Invalid canonical release version or repository'),
      );
      expect(Directory(p.join(root.path, 'descriptor')).existsSync(), isFalse);
    },
  );
}
