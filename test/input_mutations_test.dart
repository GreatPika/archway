import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'physical_paths_test.dart' show checkPhysical;
import 'typescript_fixture.dart' as ts;
import 'inspection_test.dart' show typescriptPolicy;
import 'dart_inspection_test.dart' show dartFixture;

void main() {
  test('conflicting shared bytes invalidate both suppliers even when final bytes match the first', () async {
    final root = await projectsFixture();
    final shared = File('${root.path}/configs/shared.json');
    final original = shared.readAsStringSync();
    final report = await checkBetweenProjects(
      root,
      beforeSecond: () => shared.writeAsStringSync('$original\n'),
      beforeThird: () => shared.writeAsStringSync(original),
    );
    expect(shared.readAsStringSync(), original);
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expectConflict(report.payload);
  });
  test('parent absence remains evidence when the compiler subsequently reads the new source', () async {
    final root = await ts.fixture(
      policy: typescriptPolicy
          .replaceFirst('scope: [src/]', 'scope: [src/, src/new.ts]')
          .replaceFirst('owns: [src/core/]', 'owns: []'),
    );
    final appeared = File('${root.path}/src/new.ts');
    final report = await Inspection(
      startProcess:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            if (!arguments.contains('--version'))
              appeared.writeAsStringSync('export {};');
            return Process.start(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
              includeParentEnvironment: false,
            );
          },
    ).check(RepositorySelection(root.path));
    final payload = report.payload;
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expect((payload['input_identity'] as Map)['rechecked'], true);
    expect(
      (payload['input_identity'] as Map)['changed_inputs'],
      contains(equals({'kind': 'repository', 'path': 'src/new.ts'})),
    );
    expect(
      (payload['input_identity'] as Map)['inputs'],
      contains(
        allOf(
          containsPair('location', {
            'kind': 'repository',
            'path': 'src/new.ts',
          }),
          containsPair('presence', 'absent'),
          containsPair('hash', null),
        ),
      ),
    );
    expect((payload['facts'] as Map)['edges'], isEmpty);
    expect((payload['violations'] as List).single['code'], 'SOURCE_UNOWNED');
    expect(payload['observed'], {'files': 2, 'analyzed_files': 2, 'edges': 0});
    for (final row in (payload['coverage'] as Map)['files']) {
      expect(row['assignment'], 'failed');
      expect(row['analysis'], 'partial');
      expect(row['unresolved_project_ids'], ['web']);
    }
    expectConservation(payload);
  });

  test('a mixed repository retains an independent Dart violation through TypeScript conflicts', () async {
    final root = await projectsFixture(mixed: true);
    final shared = File('${root.path}/configs/shared.json');
    final original = shared.readAsStringSync();
    final report = await checkBetweenProjects(
      root,
      beforeSecond: () => shared.writeAsStringSync('$original\n'),
      beforeThird: () => shared.writeAsStringSync(original),
    );
    final payload = report.payload;
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expect(payload['tool_errors'], isEmpty);
    expect(payload['observed'], {'files': 8, 'analyzed_files': 8, 'edges': 2});
    expect(
      (payload['facts'] as Map)['edges'].map((e) => e['project_id']).toSet(),
      {'c', 'd'},
    );
    expect(
      (payload['violations'] as List).map((e) => e['project_id']).toSet(),
      {'c', 'd'},
    );
    for (final file in (payload['coverage'] as Map)['files']) {
      if (!(file['path'] as String).endsWith('.dart')) continue;
      expect(file['assignment'], 'assigned');
      expect(file['analysis'], 'complete');
      expect(file['project_id'], 'd');
      expect(file['discovery_complete'], true);
      expect(file['unresolved_project_ids'], isEmpty);
    }
    expect((payload['input_identity'] as Map)['rechecked'], true);
    expectConservation(
      payload,
      expectedPaths: [
        'lib/app/main.dart',
        'lib/core/private.dart',
        ...projectPaths,
      ],
    );
  });

  test('cross-project alias disagreement invalidates both suppliers with equal target bytes', () async {
    final root = await projectsFixture();
    final shared = File('${root.path}/configs/shared.json');
    final original = shared.readAsStringSync();
    shared.deleteSync();
    File('${root.path}/configs/first.json').writeAsStringSync(original);
    File('${root.path}/configs/second.json').writeAsStringSync(original);
    final alias = Link(shared.path)..createSync('first.json');
    final report = await checkBetweenProjects(
      root,
      beforeSecond: () => alias.updateSync('second.json'),
      beforeThird: () => alias.updateSync('first.json'),
    );
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expectConflict(report.payload);
    expect(
      (report.payload['input_identity'] as Map)['aliases'],
      contains(
        equals({
          'observed_file_uri': shared.uri.toString(),
          'canonical_file_uri': File('${root.path}/configs/first.json').uri
              .toString(),
        }),
      ),
    );
  });

  test('file-to-directory conflict cannot restore discovery by restoring the original file', () async {
    final root = await projectsFixture();
    final shared = File('${root.path}/configs/shared.json');
    final original = shared.readAsStringSync();
    final report = await checkBetweenProjects(
      root,
      beforeSecond: () {
        shared.deleteSync();
        Directory(shared.path).createSync();
      },
      beforeThird: () {
        Directory(shared.path).deleteSync();
        shared.writeAsStringSync(original);
      },
    );
    final payload = report.payload;
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expect(payload['analysis_complete'], false);
    expect((payload['input_identity'] as Map)['rechecked'], true);
    expect((payload['input_identity'] as Map)['atomic_snapshot'], false);
    expect(
      (payload['input_identity'] as Map)['changed_inputs'],
      contains(equals({'kind': 'repository', 'path': 'configs/shared.json'})),
    );
    expect((payload['facts'] as Map)['edges'].single['project_id'], 'c');
    expect((payload['violations'] as List).single['project_id'], 'c');
    expect(payload['observed'], {'files': 6, 'analyzed_files': 6, 'edges': 1});
    for (final row in (payload['coverage'] as Map)['files']) {
      final id = (row['path'] as String).split('/')[1];
      expect(row['candidates'], [
        {'project_id': id, 'context_id': 'typescript:$id'},
      ]);
      expect(row['analysis'], 'partial');
      expect(row['assignment'], 'failed');
      expect(row['discovery_complete'], false);
      expect(row['unresolved_project_ids'], ['a', 'b']);
    }
    expectConservation(payload, expectedPaths: projectPaths);
  });

  test('a recheck I/O failure remains incomplete while later changed inputs and findings survive', () async {
    final root = await ts.fixture(
      config: '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
    );
    await File('${root.path}/base.json').writeAsString('{}');
    final alias = Link('${root.path}/config.alias.json');
    await alias.create('base.json');
    final report = await runZoned(
      () => checkPhysical(root, 2),
      zoneValues: {
        #archwayBeforeInputRecheck: () {
          alias.updateSync('config.alias.json');
          File('${root.path}/src/core/private.ts')
              .writeAsStringSync('export const value = 2;');
        },
      },
    );
    final payload = report['payload'];
    expect(report['status'], 'incomplete');
    expect(payload['analysis_complete'], false);
    expect(payload['input_identity']['rechecked'], false);
    expect(payload['input_identity']['atomic_snapshot'], false);
    expect(
      payload['input_identity']['changed_inputs'],
      contains(equals({'kind': 'repository', 'path': 'src/core/private.ts'})),
    );
    expect(
      payload['tool_errors'].map((d) => d['code']),
      contains('INPUT_RECHECK_FAILED'),
    );
    expect(payload['violations'].single['code'], 'DEPENDENCY_NOT_ALLOWED');
    expect(payload['observed'], {'files': 2, 'analyzed_files': 2, 'edges': 1});
    expectConservation(payload);
  });

  test('an unreadable selected directory is a corpus gap, not an empty clean region', () async {
    final root = await ts.fixture(
      policy: typescriptPolicy.replaceFirst(
        'scope: [src/]',
        'scope: [src/, unreadable/]',
      ),
    );
    final gap = await Directory('${root.path}/unreadable').create();
    await File('${gap.path}/hidden.ts').writeAsString('export {};');
    expect((await Process.run('/bin/chmod', ['000', gap.path])).exitCode, 0);
    try {
      var unreadable = false;
      try {
        await gap.list().toList();
      } on FileSystemException catch (error) {
        expect(error.osError?.errorCode, 13);
        unreadable = true;
      }
      if (!unreadable) {
        markTestSkipped('This process can bypass directory read permissions.');
        return;
      }
      final report = await checkPhysical(root, 2);
      final payload = report['payload'];
      expect(report['status'], 'incomplete');
      expect(payload['analysis_complete'], false);
      expect(
        payload['unknowns'].map((d) => d['code']),
        contains('CORPUS_ENUMERATION_FAILED'),
      );
      expect(payload['input_identity']['rechecked'], true);
      expect(payload['input_identity']['atomic_snapshot'], false);
      expect(payload['input_identity']['changed_inputs'], isEmpty);
      expect(payload['violations'].single['code'], 'DEPENDENCY_NOT_ALLOWED');
      expect(payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      });
      expectConservation(payload);
    } finally {
      expect((await Process.run('/bin/chmod', ['700', gap.path])).exitCode, 0);
    }
  }, skip: !Platform.isLinux);

  for (final mutation in [
    'bytes',
    'absent probe',
    'corpus inventory',
    'config inventory',
    'alias mapping',
    'disappearance',
  ]) {
    test(
      'CLI preserves baseline findings after $mutation changes at final recheck',
      () async {
        final root = await ts.fixture(
          main:
              "import {value} from '../core/private';\n" +
              (mutation == 'absent probe' ? "import './missing';\n" : ''),
          config: '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
        );
        for (final name in ['first.json', 'second.json']) {
          await File('${root.path}/$name').writeAsString(
            '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
          );
        }
        await Link('${root.path}/config.alias.json').create('first.json');
        final changedPath = switch (mutation) {
          'bytes' || 'disappearance' => 'src/core/private.ts',
          'absent probe' => 'src/app/missing.ts',
          'corpus inventory' => 'src/app',
          'config inventory' => './',
          _ => 'config.alias.json',
        };
        final report = await runZoned(
          () => checkPhysical(root, 2),
          zoneValues: {
            #archwayBeforeInputRecheck: () {
              switch (mutation) {
                case 'bytes':
                  File('${root.path}/src/core/private.ts')
                      .writeAsStringSync('export const value = 2;\n');
                case 'absent probe':
                  File('${root.path}/src/app/missing.ts')
                      .writeAsStringSync('export {};');
                case 'corpus inventory':
                  File('${root.path}/src/app/new.ts')
                      .writeAsStringSync('export {};');
                case 'config inventory':
                  File('${root.path}/tsconfig.extra.json')
                      .writeAsStringSync('{}');
                case 'alias mapping':
                  Link('${root.path}/config.alias.json')
                      .updateSync('second.json');
                case 'disappearance':
                  File('${root.path}/src/core/private.ts').deleteSync();
              }
            },
          },
        );
        expect(report['status'], 'incomplete');
        expect(report.keys.toSet(), {
          'command',
          'schema_version',
          'tool_versions',
          'resolved_root',
          'policy_path',
          'policy_hash',
          'status',
          'exit_code',
          'diagnostics',
          'payload',
        });
        expect(report['tool_versions']['typescript'], '5.9.3');
        final payload = report['payload'];
        expect(payload['analysis_complete'], false);
        expect(payload['tool_errors'], isEmpty);
        expect(payload['input_identity']['rechecked'], true);
        expect(payload['input_identity']['atomic_snapshot'], false);
        expect(
          payload['input_identity']['changed_inputs'],
          contains(equals({'kind': 'repository', 'path': changedPath})),
        );
        expect(
          payload['unknowns'].map((d) => d['code']),
          contains('INPUT_CHANGED'),
        );
        expect(payload['observed'], {
          'files': 2,
          'analyzed_files': 2,
          'edges': mutation == 'absent probe' ? 2 : 1,
        });
        expect(payload['violations'].single['code'], 'DEPENDENCY_NOT_ALLOWED');
        if (mutation == 'absent probe') {
          expect(
            payload['input_identity']['inputs'],
            contains(
              allOf(
                containsPair('location', {
                  'kind': 'repository',
                  'path': changedPath,
                }),
                containsPair('presence', 'absent'),
                containsPair('hash', null),
              ),
            ),
          );
        }
        if (mutation == 'alias mapping') {
          expect(
            payload['input_identity']['aliases'],
            contains(
              equals({
                'observed_file_uri': File('${root.path}/config.alias.json').uri
                    .toString(),
                'canonical_file_uri': File('${root.path}/first.json').uri
                    .toString(),
              }),
            ),
          );
        }
        expectConservation(payload);
      },
    );
  }
}

Future<Report> checkBetweenProjects(
  Directory root, {
  required void Function() beforeSecond,
  required void Function() beforeThird,
}) async {
  var helpers = 0;
  final report = await Inspection(
    startProcess:
        (
          executable,
          arguments, {
          required workingDirectory,
          required environment,
        }) async {
          if (!arguments.contains('--version')) {
            helpers++;
            if (helpers == 2) beforeSecond();
            if (helpers == 3) beforeThird();
          }
          return Process.start(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            includeParentEnvironment: false,
          );
        },
  ).check(RepositorySelection(root.path));
  expect(helpers, 3, reason: 'All three real compiler requests completed.');
  return report;
}

Future<Directory> projectsFixture({bool mixed = false}) async {
  final root = mixed
      ? await dartFixture()
      : await Directory.systemTemp.createTemp('archway-mutations-');
  if (!mixed) addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/package.json').writeAsString('{"type":"commonjs"}');
  await Directory('${root.path}/configs').create();
  await File('${root.path}/configs/shared.json').writeAsString(
    '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
  );
  for (final id in ['a', 'b', 'c']) {
    await Directory('${root.path}/src/$id').create(recursive: true);
    await File('${root.path}/src/$id/main.ts')
        .writeAsString("import './private';\n");
    await File('${root.path}/src/$id/private.ts').writeAsString('export {};');
    await File('${root.path}/$id.json').writeAsString(
      jsonEncode({
        if (id != 'c') 'extends': './configs/shared.json',
        if (id == 'c')
          'compilerOptions': {'target': 'ES2022', 'module': 'CommonJS'},
        'files': ['src/$id/main.ts'],
      }),
    );
  }
  await File('${root.path}/architecture.yaml').writeAsString('''version: 1
projects:
${mixed ? '  - {id: d, adapter: dart, package_roots: [./]}' : ''}
  - {id: c, adapter: typescript, tsconfig: c.json}
  - {id: b, adapter: typescript, tsconfig: b.json}
  - {id: a, adapter: typescript, tsconfig: a.json}
scope: [src/${mixed ? ', lib/' : ''}]
exclude: []
nodes:
  - {id: callers, responsibility: Callers, owns: [src/a/main.ts, src/b/main.ts, src/c/main.ts${mixed ? ', lib/app/' : ''}], allows: [], public: []}
  - {id: private, responsibility: Private, owns: [src/a/private.ts, src/b/private.ts, src/c/private.ts${mixed ? ', lib/core/' : ''}], allows: [], public: []}
''');
  return root;
}

void expectConflict(Map payload) {
  expect(payload['analysis_complete'], false);
  expect(payload['tool_errors'], isEmpty);
  expect(payload['input_identity']['rechecked'], true);
  expect(payload['input_identity']['atomic_snapshot'], false);
  expect(
    payload['input_identity']['changed_inputs'],
    contains(equals({'kind': 'repository', 'path': 'configs/shared.json'})),
  );
  expect(payload['unknowns'].map((d) => d['code']), contains('INPUT_CHANGED'));
  expect(payload['observed'], {'files': 6, 'analyzed_files': 6, 'edges': 1});
  expect(payload['facts']['edges'].single['project_id'], 'c');
  expect(
    payload['violations'].map((d) => [d['code'], d['project_id']]).toList(),
    [
      ['DEPENDENCY_NOT_ALLOWED', 'c'],
    ],
  );
  for (final row in payload['coverage']['files']) {
    final id = (row['path'] as String).split('/')[1];
    expect(row['assignment'], 'failed');
    expect(row['analysis'], 'partial');
    expect(row['discovery_complete'], false);
    expect(row['unresolved_project_ids'], ['a', 'b']);
    expect(row['project_id'], isNull);
    expect(row['context_id'], isNull);
    expect(row['candidates'], [
      {'project_id': id, 'context_id': 'typescript:$id'},
    ]);
  }
  expect(payload['coverage']['projects'], [
    for (final id in ['a', 'b', 'c'])
      {
        'project_id': id,
        'adapter': 'typescript',
        'status': id == 'c' ? 'complete' : 'partial',
        'files': 2,
        'analyzed_files': 2,
        'contexts': [
          {
            'context_id': 'typescript:$id',
            'descriptor': {'tsconfig': '$id.json'},
          },
        ],
      },
  ]);
  expectConservation(payload, expectedPaths: projectPaths);
}

const projectPaths = [
  'src/a/main.ts',
  'src/a/private.ts',
  'src/b/main.ts',
  'src/b/private.ts',
  'src/c/main.ts',
  'src/c/private.ts',
];

void expectConservation(
  Map payload, {
  List<String> expectedPaths = const ['src/app/main.ts', 'src/core/private.ts'],
}) {
  final files = payload['coverage']['files'] as List;
  final projects = payload['coverage']['projects'] as List;
  final edges = payload['facts']['edges'] as List;
  expect(files.map((f) => f['path']).toList(), expectedPaths);
  final paths = files.map((f) => f['path']).toSet();
  expect(paths.length, files.length);
  expect(payload['observed'], {
    'files': files.length,
    'analyzed_files': files
        .where((f) => ['complete', 'partial'].contains(f['analysis']))
        .length,
    'edges': edges.length,
  });
  final contexts = {
    for (final project in projects)
      for (final context in project['contexts'])
        '${project['project_id']}|${context['context_id']}',
  };
  for (final file in files) {
    if (file['assignment'] == 'assigned') {
      expect(file['candidates'], [
        {'project_id': file['project_id'], 'context_id': file['context_id']},
      ]);
      expect(file['discovery_complete'], true);
      expect(file['unresolved_project_ids'], isEmpty);
    } else {
      expect(file['project_id'], isNull);
      expect(file['context_id'], isNull);
    }
    for (final candidate in file['candidates']) {
      expect(
        contexts,
        contains('${candidate['project_id']}|${candidate['context_id']}'),
      );
    }
    for (final unresolved in file['unresolved_project_ids']) {
      expect(projects.map((p) => p['project_id']), contains(unresolved));
    }
  }
  for (final edge in edges) {
    expect(paths, contains(edge['source']));
    final source = files.singleWhere((f) => f['path'] == edge['source']);
    expect(
      source['candidates'],
      contains(
        equals({
          'project_id': edge['project_id'],
          'context_id': edge['context_id'],
        }),
      ),
    );
    expect(edge['source_range']['path'], edge['source']);
    expect(contexts, contains('${edge['project_id']}|${edge['context_id']}'));
  }
  for (final project in projects) {
    final members = files.where(
      (f) => (f['candidates'] as List).any(
        (c) => c['project_id'] == project['project_id'],
      ),
    );
    expect(project['files'], members.length);
    expect(
      project['analyzed_files'],
      members
          .where((f) => ['complete', 'partial'].contains(f['analysis']))
          .length,
    );
  }
  final inputs = payload['input_identity']['inputs'] as List;
  expect(
    inputs
        .map((i) => '${i['kind']}|${jsonEncode(i['location'])}')
        .toSet()
        .length,
    inputs.length,
  );
}
