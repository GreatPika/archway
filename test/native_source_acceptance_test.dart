import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_source_acceptance.dart';

void main() {
  test(
    'tracked snapshot and archive bytes bind original receipt fields',
    () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      SourceFixture.write(fixture.repo, 'untracked.txt', 'excluded');
      final proof = await fixture.run();
      expect(fixture.calls, ['source-pub-get', 'source-tests']);
      expect(proof.keys.toSet(), {
        'source',
        'snapshot_root',
        'dart',
        'target',
        'snapshot_manifest',
        'snapshot_manifest_sha256',
        'assets',
        'preparation',
        'execution',
        'tests',
      });
      expect(proof['target'], 'linux-x64');
      expect(proof['tests'], {
        'suites': ['test/example_test.dart', 'test/other_test.dart'],
        'passed': 2,
        'skipped': [],
      });
      final manifest = File(p.join(fixture.output.path, 'source-files.json'));
      expect(
        proof['snapshot_manifest_sha256'],
        sha256.convert(manifest.readAsBytesSync()).toString(),
      );
      expect(
        (jsonDecode(manifest.readAsStringSync()) as Map).keys,
        isNot(contains('untracked.txt')),
      );
      expect(Directory(proof['snapshot_root'] as String).existsSync(), isFalse);
    },
  );
  test('source temporaries share a canonical private directory without Python binding', () {
    final root = Directory.systemTemp.createTempSync('source-env-');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory(p.join(root.path, 'child')).createSync();
    final supplied = {'PATH': '', 'ARCHWAY_TEST_PYTHON': 'untrusted'};
    final env = sourceTestEnvironment(
      supplied,
      Directory(p.join(root.path, 'child', '..')),
    );
    for (final key in ['TMPDIR', 'TMP', 'TEMP', 'RUNNER_TEMP']) {
      expect(
        env[key],
        Directory(p.join(root.path, 'test-tmp')).resolveSymbolicLinksSync(),
      );
    }
    expect(env['PATH'], '');
    expect(env.containsKey('ARCHWAY_TEST_PYTHON'), isFalse);
    expect(supplied['ARCHWAY_TEST_PYTHON'], 'untrusted');
  });
  for (final changed in [
    'pubspec.lock',
    'lib/code.dart',
    'native/linux-x64/libarchway_io.so',
    'assets/typescript/vendor/package/index.js',
  ]) {
    test('post-test snapshot mutation is rejected: $changed', () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      await expectLater(
        fixture.run(
          execute: (name, command, cwd, env, logs) async {
            final proof = await fixture.execute(name, command, cwd, env, logs);
            if (name == 'source-tests')
              File(p.join(cwd, changed)).writeAsStringSync('mutated');
            return proof;
          },
        ),
        throwsFormatException,
      );
      expect(Directory(fixture.snapshot!).existsSync(), isFalse);
    });
  }
  test('lock mutation during preparation prevents test execution', () async {
    final fixture = SourceFixture();
    addTearDown(fixture.close);
    await expectLater(
      fixture.run(
        execute: (name, command, cwd, env, logs) async {
          final proof = await fixture.execute(name, command, cwd, env, logs);
          File(p.join(cwd, 'pubspec.lock')).writeAsStringSync('mutated');
          return proof;
        },
      ),
      throwsFormatException,
    );
    expect(fixture.calls, ['source-pub-get']);
  });
  test('original tracked sources must remain unchanged', () async {
    final fixture = SourceFixture();
    addTearDown(fixture.close);
    await expectLater(
      fixture.run(
        execute: (name, command, cwd, env, logs) async {
          final proof = await fixture.execute(name, command, cwd, env, logs);
          if (name == 'source-tests')
            SourceFixture.write(fixture.repo, 'lib/code.dart', 'mutated');
          return proof;
        },
      ),
      throwsStateError,
    );
  });
  test(
    'missing mandatory fixture is rejected before any command or snapshot',
    () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      File(
        p.join(
          fixture.fixtures['git_fixture']!,
          '.dart_tool/package_config.json',
        ),
      ).deleteSync();
      await expectLater(fixture.run(), throwsFormatException);
      expect(fixture.calls, isEmpty);
      expect(fixture.output.listSync(), isEmpty);
    },
  );
  test(
    'tracked asset collision is rejected without running commands',
    () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      SourceFixture.write(
        fixture.repo,
        'native/linux-x64/libarchway_io.so',
        'tracked bridge',
      );
      fixture.git(['add', '.']);
      fixture.git(['commit', '-qm', 'collision']);
      await expectLater(fixture.run(), throwsFormatException);
      expect(fixture.calls, isEmpty);
    },
  );
  test(
    'nonordinary replacement cannot retain the snapshot hash contract',
    () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      await expectLater(
        fixture.run(
          execute: (name, command, cwd, env, logs) async {
            final proof = await fixture.execute(name, command, cwd, env, logs);
            if (name == 'source-tests') {
              final file = File(p.join(cwd, 'lib/code.dart'));
              file.deleteSync();
              Directory(file.path).createSync();
            }
            return proof;
          },
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'incomplete reporter inventory is rejected after a successful command',
    () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      await expectLater(
        fixture.run(
          execute: (name, command, cwd, env, logs) async {
            final proof = await fixture.execute(name, command, cwd, env, logs);
            if (name == 'source-tests') {
              File(p.join(logs.path, proof['stdout'] as String))
                  .writeAsStringSync('{"type":"done","success":true}\n');
            }
            return proof;
          },
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'execution failure propagates and source temporary is removed',
    () async {
      final fixture = SourceFixture();
      addTearDown(fixture.close);
      await expectLater(
        fixture.run(
          execute: (name, command, cwd, env, logs) async {
            await fixture.execute(name, command, cwd, env, logs);
            throw StateError('runner failed');
          },
        ),
        throwsStateError,
      );
      expect(fixture.calls, ['source-pub-get']);
      expect(Directory(fixture.snapshot!).existsSync(), isFalse);
    },
  );
  test('preexisting source evidence is never overwritten', () async {
    final fixture = SourceFixture();
    addTearDown(fixture.close);
    SourceFixture.write(fixture.output, 'source-files.json', 'keep');
    await expectLater(fixture.run(), throwsA(isA<FileSystemException>()));
    expect(
      File(p.join(fixture.output.path, 'source-files.json')).readAsStringSync(),
      'keep',
    );
    expect(fixture.calls, isEmpty);
  });
}

final class SourceFixture {
  SourceFixture() {
    root = Directory.systemTemp.createTempSync('source-gate-');
    repo = Directory(p.join(root.path, 'repo'))..createSync();
    output = Directory(p.join(root.path, 'output'))..createSync();
    bundle = Directory(p.join(root.path, 'archive'))..createSync();
    for (final entry in {
      'pubspec.lock': 'locked',
      'assets/typescript/package-lock.json': '{}',
      'test/example_test.dart': 'void main() {}',
      'test/other_test.dart': 'void main() {}',
      'lib/code.dart': '// exact tracked source\n',
    }.entries) {
      write(repo, entry.key, entry.value);
    }
    git(['init', '-q']);
    git(['config', 'user.email', 'fixture@example.invalid']);
    git(['config', 'user.name', 'Source fixture']);
    git(['add', '.']);
    git(['commit', '-qm', 'fixture']);
    executable = p.join(bundle.path, 'bin', 'linux-x64', 'archway');
    write(
      bundle,
      'bin/linux-x64/archway',
      'not executed by injected source runner',
    );
    write(bundle, 'native/linux-x64/libarchway_io.so', 'archive bridge');
    write(
      bundle,
      'assets/typescript/vendor/package/index.js',
      'archive vendor',
    );
    fixtures = {'dart_sdk': p.dirname(p.dirname(Platform.resolvedExecutable))};
    for (final key in ['git_fixture', 'flutter_fixture']) {
      final dir = Directory(p.join(root.path, key))..createSync();
      fixtures[key] = dir.path;
      for (final name in [
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
      ]) {
        write(dir, name, '{}');
      }
    }
  }
  late Directory root, repo, output, bundle;
  late String executable;
  late Map<String, String> fixtures;
  final calls = <String>[];
  String? snapshot;
  void git(List<String> args) {
    final result = Process.runSync('git', ['-C', repo.path, ...args]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
  }

  static void write(Directory dir, String name, String text) {
    final file = File(p.join(dir.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  Future<Map<String, Object?>> execute(
    String name,
    List<String> command,
    String cwd,
    Map<String, String> env,
    Directory logs,
  ) async {
    calls.add(name);
    snapshot = cwd;
    expect(
      command,
      name == 'source-pub-get'
          ? [
              p.join(fixtures['dart_sdk']!, 'bin', 'dart'),
              '--suppress-analytics',
              'pub',
              'get',
              '--enforce-lockfile',
            ]
          : [
              p.join(fixtures['dart_sdk']!, 'bin', 'dart'),
              'test',
              '--reporter=json',
            ],
    );
    expect(env['ARCHWAY_PUB_GIT_FIXTURE'], fixtures['git_fixture']);
    expect(env['ARCHWAY_FLUTTER_FIXTURE'], fixtures['flutter_fixture']);
    expect(env.containsKey('ARCHWAY_TEST_PYTHON'), isFalse);
    expect(
      File(p.join(cwd, 'native/linux-x64/libarchway_io.so')).readAsStringSync(),
      'archive bridge',
    );
    expect(
      File(p.join(cwd, 'assets/typescript/vendor/package/index.js'))
          .readAsStringSync(),
      'archive vendor',
    );
    expect(File(p.join(cwd, 'untracked.txt')).existsSync(), isFalse);
    if (name == 'source-tests') {
      final events = <Map<String, Object?>>[];
      for (var id = 0; id < 2; id++) {
        events.addAll([
          {
            'type': 'suite',
            'suite': {
              'id': id,
              'path': 'test/${id == 0 ? 'example' : 'other'}_test.dart',
            },
          },
          {
            'type': 'testStart',
            'test': {
              'id': id,
              'suiteID': id,
              'name': 'example',
              'metadata': {},
            },
          },
          {
            'type': 'testDone',
            'testID': id,
            'result': 'success',
            'skipped': false,
            'hidden': false,
          },
        ]);
      }
      events.add({'type': 'done', 'success': true});
      File(p.join(logs.path, '$name.stdout.log'))
          .writeAsStringSync('${events.map(jsonEncode).join('\n')}\n');
    }
    return {'suite': name, 'stdout': '$name.stdout.log'};
  }

  Future<Map<String, Object?>> run({SourceExecute? execute}) => runSourceTests(
    repo,
    executable,
    fixtures,
    {'ARCHWAY_TEST_PYTHON': 'legacy'},
    output,
    execute: execute ?? this.execute,
  );
  void close() => root.deleteSync(recursive: true);
}
