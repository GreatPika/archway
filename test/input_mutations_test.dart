import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/policy_definition.dart';
import 'package:test/test.dart';

import 'physical_paths_test.dart' show checkPhysical;
import 'dart_inspection_test.dart' show dartFixture, dartPolicy;

void main() {
  test('conflicting shared bytes invalidate both suppliers even when final bytes match the first', () async {
    final root = await projectsFixture();
    final shared = File('${root.path}/configs/shared.yaml');
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
    final root = await dartFixture(
      policy: dartPolicy
          .replaceFirst('scope: [lib/]', 'scope: [lib/, lib/new.dart]')
          .replaceFirst('owns: [lib/core/]', 'owns: []'),
    );
    final appeared = File('${root.path}/lib/new.dart');
    final report = await Inspection(
      startProcess:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            if (arguments.contains('--version'))
              appeared.writeAsStringSync('class Added {}');
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
      contains(equals({'kind': 'repository', 'path': 'lib/new.dart'})),
    );
    expect(
      (payload['input_identity'] as Map)['inputs'],
      contains(
        allOf(
          containsPair('location', {
            'kind': 'repository',
            'path': 'lib/new.dart',
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
      expect(row['unresolved_project_ids'], ['app']);
    }
    expectConservation(payload);
  });

  test('an independent Dart package retains its violation through shared-input conflicts', () async {
    final root = await projectsFixture(includeIndependentPackage: true);
    final shared = File('${root.path}/configs/shared.yaml');
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
      if (!(file['path'] as String).startsWith('lib/')) continue;
      expect(file['assignment'], 'failed');
      expect(file['analysis'], 'partial');
      expect(file['project_id'], isNull);
      expect(file['discovery_complete'], false);
      expect(file['unresolved_project_ids'], ['a', 'b']);
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
    final shared = File('${root.path}/configs/shared.yaml');
    final original = shared.readAsStringSync();
    shared.deleteSync();
    File('${root.path}/configs/first.yaml').writeAsStringSync(original);
    File('${root.path}/configs/second.yaml').writeAsStringSync(original);
    final alias = Link(shared.path)..createSync('first.yaml');
    final report = await checkBetweenProjects(
      root,
      beforeSecond: () => alias.updateSync('second.yaml'),
      beforeThird: () => alias.updateSync('first.yaml'),
    );
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expectConflict(report.payload);
    expect(
      (report.payload['input_identity'] as Map)['aliases'],
      contains(
        equals({
          'observed_file_uri': shared.uri.toString(),
          'canonical_file_uri': File('${root.path}/configs/first.yaml').uri
              .toString(),
        }),
      ),
    );
  });

  test('file-to-directory conflict cannot restore discovery by restoring the original file', () async {
    final root = await projectsFixture();
    final shared = File('${root.path}/configs/shared.yaml');
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
      contains(equals({'kind': 'repository', 'path': 'configs/shared.yaml'})),
    );
    expect((payload['facts'] as Map)['edges'].single['project_id'], 'c');
    expect((payload['violations'] as List).single['project_id'], 'c');
    expect(payload['observed'], {'files': 6, 'analyzed_files': 4, 'edges': 1});
    for (final row in (payload['coverage'] as Map)['files']) {
      final id = (row['path'] as String).split('/')[1];
      expect(
        (row['candidates'] as List).map((c) => c['project_id']),
        id == 'b' ? [] : [id],
      );
      expect(row['analysis'], id == 'b' ? 'not_attempted' : 'partial');
      expect(row['assignment'], 'failed');
      expect(row['discovery_complete'], false);
      expect(row['unresolved_project_ids'], ['a', 'b']);
    }
    expect(
      (payload['tool_errors'] as List).map((e) => [e['code'], e['project_id']]),
      [
        ['DART_ANALYSIS_FAILED', 'b'],
      ],
    );
    expectConservation(payload, expectedPaths: projectPaths);
  });

  test('a recheck I/O failure remains incomplete while later changed inputs and findings survive', () async {
    final root = await dartFixture();
    final report = await runZoned(
      () => checkPhysical(root, 2),
      zoneValues: {
        #archwayBeforeInputRecheck: () {
          File('${root.path}/lib/app/main.dart').deleteSync();
          Link('${root.path}/lib/app/main.dart').createSync('main.dart');
          File('${root.path}/lib/core/private.dart')
              .writeAsStringSync('class Changed {}');
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
      contains(equals({'kind': 'repository', 'path': 'lib/core/private.dart'})),
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
    final root = await dartFixture(
      policy: dartPolicy
          .replaceFirst('package_roots: [./]', 'package_roots: [lib/]')
          .replaceFirst('scope: [lib/]', 'scope: [lib/, unreadable/]'),
    );
    final gap = await Directory('${root.path}/unreadable').create();
    await File('${gap.path}/hidden.dart').writeAsString('class Added {}');
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
        final root = await dartFixture(
          main:
              "import '../core/private.dart';\n" +
              (mutation == 'absent probe' ? "import './missing.dart';\n" : ''),
        );
        for (final name in ['first.yaml', 'second.yaml']) {
          await File('${root.path}/$name').writeAsString('{}');
        }
        await Link('${root.path}/analysis_options.yaml').create('first.yaml');
        final changedPath = switch (mutation) {
          'bytes' || 'disappearance' => 'lib/core/private.dart',
          'absent probe' => 'lib/app/missing.dart',
          'corpus inventory' => 'lib/app',
          'config inventory' => './',
          _ => 'analysis_options.yaml',
        };
        final report = await runZoned(
          () => checkPhysical(root, 2),
          zoneValues: {
            #archwayBeforeInputRecheck: () {
              switch (mutation) {
                case 'bytes':
                  File('${root.path}/lib/core/private.dart')
                      .writeAsStringSync('class Changed {}\n');
                case 'absent probe':
                  File('${root.path}/lib/app/missing.dart')
                      .writeAsStringSync('class Added {}');
                case 'corpus inventory':
                  File('${root.path}/lib/app/new.dart')
                      .writeAsStringSync('class Added {}');
                case 'config inventory':
                  File('${root.path}/extra_options.yaml')
                      .writeAsStringSync('{}');
                case 'alias mapping':
                  Link('${root.path}/analysis_options.yaml')
                      .updateSync('second.yaml');
                case 'disappearance':
                  File('${root.path}/lib/core/private.dart').deleteSync();
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
        expect(report['tool_versions']['dart_sdk'], '3.13.5');
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
                'observed_file_uri': File('${root.path}/analysis_options.yaml')
                    .uri
                    .toString(),
                'canonical_file_uri': File('${root.path}/first.yaml').uri
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
  final inspected = <String>[];
  final report = await runZoned(
    () => Inspection().check(RepositorySelection(root.path)),
    zoneValues: {
      #archwayBeforeProjectInspection: (String id) {
        inspected.add(id);
        if (id == 'b') beforeSecond();
        if (id == 'c') beforeThird();
      },
    },
  );
  expect(inspected, containsAllInOrder(['a', 'b', 'c']));
  return report;
}

Future<Directory> projectsFixture({
  bool includeIndependentPackage = false,
}) async {
  final root = await dartFixture();
  if (!includeIndependentPackage)
    await Directory('${root.path}/lib').delete(recursive: true);
  await Directory('${root.path}/configs').create();
  await File('${root.path}/configs/shared.yaml').writeAsString('{}');
  for (final id in ['a', 'b', 'c']) {
    final package = '${root.path}/packages/$id';
    await Directory('$package/lib').create(recursive: true);
    await Directory('$package/.dart_tool').create();
    await File('$package/lib/main.dart')
        .writeAsString("import './private.dart';\n");
    await File('$package/lib/private.dart').writeAsString('class Private {}');
    await File('$package/pubspec.yaml').writeAsString(
      'name: package_$id\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n',
    );
    await File('$package/.dart_tool/package_config.json').writeAsString(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'package_$id',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
        ],
        'generator': 'pub',
        'generatorVersion': '3.13.5',
      }),
    );
    await File(
      '$package/analysis_options.yaml',
    ).writeAsString(id == 'c' ? '{}' : 'include: ../../configs/shared.yaml\n');
  }
  await File('${root.path}/architecture.yaml').writeAsString('''version: 1
projects:
${includeIndependentPackage ? '  - {id: d, adapter: dart, package_roots: [lib/]}' : ''}
  - {id: c, adapter: dart, package_roots: [packages/c/]}
  - {id: b, adapter: dart, package_roots: [packages/b/]}
  - {id: a, adapter: dart, package_roots: [packages/a/]}
scope: [packages/${includeIndependentPackage ? ', lib/' : ''}]
exclude: []
nodes:
  - {id: callers, responsibility: Callers, owns: [packages/a/lib/main.dart, packages/b/lib/main.dart, packages/c/lib/main.dart${includeIndependentPackage ? ', lib/app/' : ''}], allows: [], public: []}
  - {id: private, responsibility: Private, owns: [packages/a/lib/private.dart, packages/b/lib/private.dart, packages/c/lib/private.dart${includeIndependentPackage ? ', lib/core/' : ''}], allows: [], public: []}
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
    contains(equals({'kind': 'repository', 'path': 'configs/shared.yaml'})),
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
    expect((row['candidates'] as List).map((c) => c['project_id']), [id]);
  }
  for (final project in payload['coverage']['projects']) {
    expect(project['adapter'], 'dart');
    expect(
      project['status'],
      project['project_id'] == 'c' ? 'complete' : 'partial',
    );
    expect(project['files'], 2);
    expect(project['analyzed_files'], 2);
    expect(project['contexts'], isNotEmpty);
  }
  expectConservation(payload, expectedPaths: projectPaths);
}

const projectPaths = [
  'packages/a/lib/main.dart',
  'packages/a/lib/private.dart',
  'packages/b/lib/main.dart',
  'packages/b/lib/private.dart',
  'packages/c/lib/main.dart',
  'packages/c/lib/private.dart',
];

void expectConservation(
  Map payload, {
  List<String> expectedPaths = const [
    'lib/app/main.dart',
    'lib/core/private.dart',
  ],
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
