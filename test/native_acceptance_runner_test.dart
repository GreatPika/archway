import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_acceptance.dart';
import '../tool/ci/native_acceptance_runner.dart';
import '../tool/ci/native_source_acceptance.dart';
import '../tool/release/installation_identity.dart';

const names = [
  'plan_query',
  'cli',
  'catalogue_export',
  'check',
  'dart_check',
  'physical_path',
  'alias_wire',
  'alias_hop_recheck',
  'alias_trace_gap',
  'dart_resource',
  'runtime',
  'runtime_request',
  'runtime_preflight',
  'native_asset',
  'native_abi',
  'native_fault',
  'package_provenance',
  'dart_flutter',
];

// The Windows job launcher preserves Win32 errors; POSIX uses Process.start.
Matcher missingExecutableError(String executable, {required bool windows}) =>
    windows
    ? isA<OSError>()
          .having((e) => e.message, 'operation', 'CreateProcessW')
          .having((e) => e.errorCode, 'errorCode', 2)
    : isA<ProcessException>()
          .having((e) => e.executable, 'executable', executable)
          .having((e) => e.arguments, 'arguments', isEmpty)
          .having((e) => e.errorCode, 'errorCode', 2);

void main() {
  late RunnerFixture f;
  setUp(() => f = RunnerFixture());
  tearDown(() => f.root.deleteSync(recursive: true));

  test(
    'returns exact native receipt and brackets every stage with verification',
    () async {
      final identity = await sourceIdentity(f.repo);
      final result = await f.run();
      expect(result, {
        'scope': 'Complete applicable final native archive process suites',
        'source': identity,
        'source_root': f.repo.resolveSymbolicLinksSync(),
        'node_path': File(f.node).resolveSymbolicLinksSync(),
        'output_root': f.output.resolveSymbolicLinksSync(),
        'fixtures': readFixtures(f.manifest).provenance,
        'suites': [
          for (final name in names) {'suite': name, 'exit_code': 0},
        ],
        'source_suite': f.sourceProof,
      });
      expect(identical(result['source_suite'], f.sourceProof), isTrue);
      expect(f.events, [
        for (final name in [...names, 'source']) ...['verify', name, 'verify'],
      ]);
      expect(f.calls, names);
    },
  );
  for (final failed in ['plan_query', 'runtime', 'dart_flutter']) {
    test(
      'completed $failed failure preserves evidence and still runs source',
      () async {
        await expectLater(
          f.run(
            execute: (name, cmd, cwd, env, logs, {required timeout}) async {
              final proof = await f.execute(name, cmd, cwd, env, logs, timeout: timeout);
              if (name == failed) {
                final failure = {...proof, 'exit_code': 7};
                RunnerFixture.write(logs, '$name.json', jsonEncode(failure));
                throw SuiteExitFailure(failure);
              }
              return proof;
            },
          ),
          throwsA(
            isA<StateError>().having((e) => '$e', 'summary', contains(failed)),
          ),
        );
        expect(f.calls, names);
        expect(f.events.lastIndexOf('source'), f.events.length - 2);
        expect(
          jsonDecode(
            File(p.join(f.output.path, '$failed.json')).readAsStringSync(),
          ),
          {'suite': failed, 'exit_code': 7},
        );
        final failures = jsonDecode(
          File(p.join(f.output.path, 'failures.json')).readAsStringSync(),
        ) as List;
        expect(failures.single['suite'], failed);
        expect(failures.single['error'], contains('exit 7'));
      },
    );
  }

  test(
    'source failure is durable before final archive and source verification',
    () async {
      await expectLater(
        f.run(
          source:
              (
                repo,
                binary,
                paths,
                env,
                logs, {
                SourceExecute execute = executeSuite,
              }) async {
                f.events.add('source');
                RunnerFixture.write(repo, 'pubspec.lock', 'drift');
                throw TimeoutException('source timed out');
              },
          verify: () {
            f.events.add('verify');
            if (f.events.contains('source')) {
              final failures = jsonDecode(
                File(p.join(f.output.path, 'failures.json')).readAsStringSync(),
              ) as List;
              expect(failures.single['suite'], 'source');
              expect(failures.single['error'], contains('source timed out'));
            }
          },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'integrity',
            contains('clean tracked sources'),
          ),
        ),
      );
      expect(f.events.last, 'verify');
    },
  );
  for (final error in [
    TimeoutException('timeout'),
    ProcessException('absent', []),
    const FormatException('receipt'),
  ]) {
    test('$error stops before later suites but verifies archive', () async {
      await expectLater(
        f.run(
          execute: (name, cmd, cwd, env, logs, {required timeout}) async {
            await f.execute(name, cmd, cwd, env, logs, timeout: timeout);
            throw error;
          },
        ),
        throwsA(same(error)),
      );
      expect(f.events, ['verify', 'plan_query', 'verify']);
    });
  }
  for (final boundary in [1, 2, 37, 38]) {
    test(
      'archive drift at verification $boundary prevents subsequent execution',
      () async {
        var checks = 0;
        await expectLater(
          f.run(
            verify: () async {
              f.events.add('verify');
              if (++checks == boundary) throw StateError('archive drift');
            },
          ),
          throwsA(
            isA<StateError>().having(
              (e) => '$e',
              'archive',
              contains('archive drift'),
            ),
          ),
        );
        expect(checks, boundary);
        expect(
          f.calls.length,
          boundary == 1
              ? 0
              : boundary == 2
              ? 1
              : 18,
        );
        expect(f.events.contains('source'), boundary == 38);
      },
    );
  }
  for (final kind in ['directory', 'file', if (!Platform.isWindows) 'link']) {
    test('preexisting $kind output is never replaced', () async {
      f.output.parent.createSync(recursive: true);
      if (kind == 'directory') {
        f.output.createSync();
      } else if (kind == 'file') {
        File(f.output.path).writeAsStringSync('prior');
      } else {
        Link(f.output.path).createSync(p.join(f.root.path, 'absent'));
      }
      await expectLater(f.run(), throwsA(isA<FileSystemException>()));
      expect(f.events, isEmpty);
      if (kind == 'file') {
        expect(File(f.output.path).readAsStringSync(), 'prior');
      }
      expect(
        FileSystemEntity.typeSync(f.output.path, followLinks: false),
        kind == 'directory'
            ? FileSystemEntityType.directory
            : kind == 'file'
            ? FileSystemEntityType.file
            : FileSystemEntityType.link,
      );
    });
  }
  test(
    'changed clean commit also invalidates initial source identity',
    () async {
      await expectLater(
        f.run(
          source:
              (
                repo,
                binary,
                paths,
                env,
                logs, {
                SourceExecute execute = executeSuite,
              }) async {
                f.events.add('source');
                RunnerFixture.write(repo, 'pubspec.lock', 'new lock');
                f.git(['add', '.']);
                f.git(['commit', '-qm', 'new identity']);
                return f.sourceProof;
              },
        ),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'source',
            contains('sources changed'),
          ),
        ),
      );
      expect(f.events.last, 'verify');
    },
  );
  test('source error without drift remains an overall failure', () async {
    await expectLater(
      f.run(
        source:
            (
              repo,
              binary,
              paths,
              env,
              logs, {
              SourceExecute execute = executeSuite,
            }) async {
              f.events.add('source');
              throw const FormatException('preparation failed');
            },
      ),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'source failure',
          contains('preparation failed'),
        ),
      ),
    );
    expect(f.events.last, 'verify');
  });
  test(
    'real executeSuite nonzero proof survives collection and source still runs',
    () async {
      final child = RunnerFixture.write(
        f.root,
        'child.dart',
        "import 'dart:io'; void main() { stdout.write('partial'); stderr.write('failed'); exit(7); }",
      );
      await expectLater(
        f.run(
          execute: (name, cmd, cwd, env, logs, {required timeout}) async {
            final stub = await f.execute(name, cmd, cwd, env, logs, timeout: timeout);
            if (name != 'plan_query') return stub;
            return executeSuite(
              name,
              [Platform.resolvedExecutable, child.path],
              cwd,
              env,
              logs,
              timeout: timeout,
            );
          },
        ),
        throwsStateError,
      );
      expect(
        File(p.join(f.output.path, 'plan_query.stdout.log')).readAsStringSync(),
        'partial',
      );
      final proof = jsonDecode(
        File(p.join(f.output.path, 'plan_query.json')).readAsStringSync(),
      );
      expect(proof['exit_code'], 7);
      expect(proof['timed_out'], false);
      expect(proof['timeout_seconds'], 600);
      expect(f.calls, names);
      expect(f.events.contains('source'), true);
    },
  );
  test(
    'default source gate uses same execute seam and preserves its report',
    () async {
      RunnerFixture.write(f.repo, 'test/example_test.dart', 'void main() {}');
      f.git(['add', '.']);
      f.git(['commit', '-qm', 'source suite']);
      final bundle = Directory(p.join(f.root.path, 'bundle'));
      RunnerFixture.write(
        bundle,
        'native/linux-x64/libarchway_io.so',
        'bridge',
      );
      RunnerFixture.write(bundle, 'assets/typescript/vendor/a.js', 'vendor');
      for (final key in ['git_fixture', 'flutter_fixture']) {
        for (final name in [
          'pubspec.yaml',
          'pubspec.lock',
          '.dart_tool/package_config.json',
        ]) {
          RunnerFixture.write(Directory(f.paths[key]!), name, '{}');
        }
      }
      final result = await runAcceptance(
        f.repo,
        f.executable,
        f.node,
        f.manifest,
        f.output,
        () => f.events.add('verify'),
        execute: (name, cmd, cwd, env, logs, {required timeout}) async {
          if (!name.startsWith('source-'))
            return f.execute(name, cmd, cwd, env, logs, timeout: timeout);
          expect(timeout.inSeconds, name == 'source-tests' ? 900 : 600);
          f.calls.add(name);
          expect(cmd.first, p.join(f.paths['dart_sdk']!, 'bin', 'dart'));
          expect(cwd, isNot(f.repo.path));
          if (name == 'source-tests') {
            final observer = RunnerFixture.write(
              f.root,
              'observe-node.dart',
              "import 'dart:io'; void main() { "
                  "stdout.write(Platform.environment['ARCHWAY_TEST_NODE']); }",
            );
            await executeSuite(
              'source-node-environment',
              [Platform.resolvedExecutable, observer.path],
              cwd,
              env,
              logs,
            );
            expect(
              File(p.join(logs.path, 'source-node-environment.stdout.log'))
                  .readAsStringSync(),
              File(f.node).resolveSymbolicLinksSync(),
            );
            final events = [
              {
                'type': 'suite',
                'suite': {'id': 0, 'path': 'test/example_test.dart'},
              },
              {
                'type': 'testStart',
                'test': {
                  'id': 1,
                  'suiteID': 0,
                  'name': 'example',
                  'metadata': {},
                },
              },
              {
                'type': 'testDone',
                'testID': 1,
                'result': 'success',
                'skipped': false,
                'hidden': false,
              },
              {'type': 'done', 'success': true},
            ];
            RunnerFixture.write(
              logs,
              '$name.stdout.log',
              '${events.map(jsonEncode).join('\n')}\n',
            );
          }
          return {'suite': name, 'stdout': '$name.stdout.log'};
        },
      );
      expect(f.calls, [...names, 'source-pub-get', 'source-tests']);
      final report = result['source_suite'] as Map;
      expect(report['tests'], {
        'suites': ['test/example_test.dart'],
        'passed': 1,
        'skipped': [],
      });
      expect(
        File(p.join(f.output.path, 'source-files.json')).existsSync(),
        true,
      );
      expect(report['source'], result['source']);
      expect(f.events.where((e) => e == 'verify').length, 38);
    },
  );
  test('real spawn failure retains its receipt and stops the runner', () async {
    await expectLater(
      f.run(
        execute: (name, cmd, cwd, env, logs, {required timeout}) async {
          await f.execute(name, cmd, cwd, env, logs, timeout: timeout);
          return executeSuite(
            name,
            [p.join(f.root.path, 'absent')],
            cwd,
            env,
            logs,
            timeout: timeout,
          );
        },
      ),
      throwsA(
        missingExecutableError(
          p.join(f.root.path, 'absent'),
          windows: Platform.isWindows,
        ),
      ),
    );
    expect(f.events, ['verify', 'plan_query', 'verify']);
    final proof = jsonDecode(
      File(p.join(f.output.path, 'plan_query.json')).readAsStringSync(),
    );
    expect(proof['exit_code'], null);
    expect(proof['timed_out'], false);
    expect(
      File(p.join(f.output.path, 'plan_query.stdout.log')).existsSync(),
      true,
    );
  });
  test('real source preparation failure launches no source tests', () async {
    // Missing mandatory prepared fixtures fail before the source execute seam.
    await expectLater(
      runAcceptance(
        f.repo,
        f.executable,
        f.node,
        f.manifest,
        f.output,
        () => f.events.add('verify'),
        execute: f.execute,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'source',
          contains('Missing mandatory source fixture'),
        ),
      ),
    );
    expect(f.calls, names);
    expect(f.events.where((e) => e == 'verify').length, 38);
    final failures = jsonDecode(
      File(p.join(f.output.path, 'failures.json')).readAsStringSync(),
    ) as List;
    expect(failures.single['suite'], 'source');
  });
}

class RunnerFixture {
  RunnerFixture() {
    repo = Directory(p.join(root.path, 'repo'))..createSync();
    output = Directory(p.join(root.path, 'new', 'output'));
    write(repo, 'pubspec.lock', 'locked');
    write(repo, 'assets/typescript/package-lock.json', '{}');
    git(['init', '-q']);
    git(['config', 'user.email', 'fixture@example.invalid']);
    git(['config', 'user.name', 'Runner fixture']);
    git(['add', '.']);
    git(['commit', '-qm', 'fixture']);
    node = write(root, 'node', 'selected node').path;
    executable = p.join(root.path, 'bundle', 'bin', 'linux-x64', 'archway');
    for (final key in fixtureKeys) {
      paths[key] = key == 'wrong_node'
          ? write(root, key, 'wrong node').path
          : (Directory(p.join(root.path, key))..createSync()).path;
    }
    manifest = write(
      root,
      'fixtures.json',
      jsonEncode({
        ...paths,
        'environment': {'PATH': 'fixture-path', 'FIXTURE_MARKER': 'prepared'},
      }),
    );
  }
  final root = Directory(
    Directory.systemTemp
        .createTempSync('acceptance-runner-')
        .resolveSymbolicLinksSync(),
  );
  late Directory repo, output;
  late File manifest;
  late String executable, node;
  final paths = <String, String>{};
  final calls = <String>[];
  final events = <String>[];
  final sourceProof = <String, Object?>{'source': 'unmodified source report'};

  void git(List<String> args) {
    final result = Process.runSync('git', ['-C', repo.path, ...args]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
  }

  static File write(Directory root, String name, String text) {
    final file = File(p.join(root.path, name));
    file.parent.createSync(recursive: true);
    return file..writeAsStringSync(text);
  }

  Future<Map<String, Object?>> execute(
    String name,
    List<String> command,
    String cwd,
    Map<String, String> env,
    Directory logs, {
    required Duration timeout,
  }) async {
    expect(timeout.inSeconds, 600);
    calls.add(name);
    events.add(name);
    final sdk = paths['dart_sdk']!;
    final tails = <String, List<String>>{
      'plan_query': [],
      'cli': [],
      'catalogue_export': [],
      'check': [node],
      'dart_check': [sdk, node, '--existing-installation'],
      'physical_path': [sdk, node],
      'alias_wire': [node],
      'alias_hop_recheck': [node],
      'alias_trace_gap': [node],
      'dart_resource': [sdk],
      'runtime': [node],
      'runtime_request': [
        node,
        p.join(logs.path, 'runtime-request-coverage.json'),
      ],
      'runtime_preflight': [node, paths['wrong_node']!, sdk],
      'native_asset': [],
      'native_abi': [],
      'native_fault': [],
      'package_provenance': [
        repo.path,
        paths['pub_fixture']!,
        paths['git_fixture']!,
        p.join(logs.path, 'package-provenance'),
      ],
      'dart_flutter': [paths['flutter_sdk']!, paths['flutter_fixture']!],
    };
    expect(command, [
      p.join(sdk, 'bin', 'dart'),
      '--suppress-analytics',
      'run',
      p.join(repo.path, 'test', '${name}_process_smoke.dart'),
      executable,
      ...tails[name]!,
    ]);
    expect(cwd, repo.resolveSymbolicLinksSync());
    expect(logs.path, output.resolveSymbolicLinksSync());
    expect(env['FIXTURE_MARKER'], 'prepared');
    expect(
      env['PATH'],
      [
        p.join(paths['dart_sdk']!, 'bin'),
        p.dirname(node),
        'fixture-path',
      ].join(Platform.isWindows ? ';' : ':'),
    );
    return {'suite': name, 'exit_code': 0};
  }

  Future<Map<String, Object?>> source(
    Directory repository,
    String binary,
    Map<String, String> fixtures,
    Map<String, String> env,
    Directory logs, {
    SourceExecute execute = executeSuite,
  }) async {
    events.add('source');
    expect(repository.path, repo.resolveSymbolicLinksSync());
    expect(binary, executable);
    expect(fixtures, paths);
    return sourceProof;
  }

  Future<Map<String, Object?>> run({
    SourceExecute? execute,
    SourceRunner? source,
    FutureOr<void> Function()? verify,
  }) => runAcceptance(
    repo,
    executable,
    node,
    manifest,
    output,
    verify ?? () => events.add('verify'),
    execute: execute ?? this.execute,
    source: source ?? this.source,
  );
}
