import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prepared Dart import checks its physical boundary and CLI envelope',
    () async {
      final root = await dartFixture();
      final out = StringBuffer(), err = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'check',
      ], CliStreams(out, err));
      final report = jsonDecode(out.toString()) as Map;
      expect(exit, 1, reason: jsonEncode(report));
      expect(err.toString(), '');
      expect(out.toString().split('\n'), hasLength(2));
      expect(report['status'], 'negative');
      expect(report['exit_code'], 1);
      expect(report['payload']['analysis_complete'], true);
      expect(report['payload']['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      });
      final edge = (report['payload']['facts']['edges'] as List).single;
      expect(edge['source'], 'lib/app/main.dart');
      expect(edge['source_range'], {
        'path': 'lib/app/main.dart',
        'start': {'line': 1, 'column': 1},
        'end': {'line': 1, 'column': 31},
      });
      expect(edge['kind'], 'import');
      expect(edge['specifier'], '../core/private.dart');
      expect(edge['resolution'], {
        'kind': 'local',
        'path': 'lib/core/private.dart',
        'canonical_file_uri': File('${root.path}/lib/core/private.dart').uri
            .toString(),
        'via_path': null,
      });
      expect(
        (report['payload']['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
      expect(report['payload']['unknowns'], isEmpty);
      expect(report['payload']['tool_errors'], isEmpty);
      expect(report['payload']['input_identity']['rechecked'], true);
      expect(report['tool_versions']['dart_sdk'], '3.13.3');
    },
  );
  test('every conditional export branch keeps known violations beside missing targets', () async {
    final root = await dartFixture(
      main: "export '../core/private.dart' if (dart.library.html) '../core/missing.dart';\n",
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(report.exitCode, 2);
    expect(
      (report.payload['violations'] as List).single['code'],
      'DEPENDENCY_NOT_ALLOWED',
    );
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.map((e) => e['specifier']), [
      '../core/missing.dart',
      '../core/private.dart',
    ]);
    expect(edges.map((e) => e['resolution']['kind']), ['unresolved', 'local']);
    expect(
      (report.payload['unknowns'] as List).map((e) => e['code']),
      contains('UNRESOLVED_IMPORT'),
    );
    final inputs = (report.payload['input_identity'] as Map)['inputs'] as List;
    expect(
      inputs.any(
        (i) =>
            i['location']['path'] == 'lib/core/missing.dart' &&
            i['presence'] == 'absent',
      ),
      true,
    );
    expect((report.payload['input_identity'] as Map)['rechecked'], true);
  });

  test('multiple actual Dart contexts carry independently hashed option descriptors', () async {
    final root = await dartFixture(
      main: 'class App {}',
      policy: dartPolicy.replaceFirst(
        'package_roots: [./]',
        'package_roots: [lib/app, lib/core]',
      ),
    );
    await File('${root.path}/shared.yaml')
        .writeAsString('analyzer:\n  language:\n    strict-casts: true\n');
    for (final name in ['app', 'core']) {
      await Directory('${root.path}/lib/$name/.dart_tool').create();
      await File('${root.path}/lib/$name/.dart_tool/package_config.json')
          .writeAsString(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': name,
                  'rootUri': '../',
                  'packageUri': './',
                  'languageVersion': '3.13',
                },
              ],
            }),
          );
      await File('${root.path}/lib/$name/analysis_options.yaml')
          .writeAsString('include: ../../shared.yaml\n');
    }
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok', reason: jsonEncode(report.payload));
    final coverage = report.payload['coverage'] as Map;
    final contexts = (coverage['projects'] as List).single['contexts'] as List;
    expect(contexts, hasLength(2));
    expect(contexts.map((c) => c['context_id']), [
      'dart:app:33d15223d4196ae70ee9462ad92aac70a1607aa5d24b1c517e89831b9988dc76',
      'dart:app:93d520db69f9009ed9fcc2367237f932da64bce9d5519b499287a56c42c18ed4',
    ]);
    expect(contexts.first['descriptor'], {
      'excluded_paths': [],
      'included_paths': ['lib/app'],
      'options_paths': ['lib/app/analysis_options.yaml', 'shared.yaml'],
      'package_config_path': 'lib/app/.dart_tool/package_config.json',
      'root': 'lib/app',
      'sdk_version': '3.13.3',
    });
    final rows = coverage['files'] as List;
    expect(rows.every((f) => f['assignment'] == 'assigned'), true);
    expect(
      rows.map((f) => f['context_id']).toSet(),
      contexts.map((c) => c['context_id']).toSet(),
    );
  });

  test(
    'named parts retain physical source owners and directed public policy',
    () async {
      final root = await dartFixture(
        main: "library named_app; part '../core/private.dart';\n",
      );
      await File('${root.path}/lib/core/private.dart')
          .writeAsString('part of named_app; class Thing {}\n');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(
        report.status,
        'negative',
        reason: jsonEncode(report.payload['tool_errors']),
      );
      expect(report.payload['analysis_complete'], true);
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      expect(
        edges.map((e) => [e['source'], e['kind'], e['resolution']['path']]),
        [
          ['lib/app/main.dart', 'part', 'lib/core/private.dart'],
          ['lib/core/private.dart', 'part_of', 'lib/app/main.dart'],
        ],
      );
      expect(
        (report.payload['violations'] as List).map(
          (d) => [d['path'], d['code']],
        ),
        [
          ['lib/app/main.dart', 'DEPENDENCY_NOT_ALLOWED'],
          ['lib/core/private.dart', 'DEPENDENCY_NOT_ALLOWED'],
        ],
      );
    },
  );

  test('an unimported prepared dependency prevents a false unique part owner', () async {
    final root = await dartFixture(
      main: "library named_app; part '../core/private.dart';\n",
      policy: dartPolicy.replaceFirst('exclude: []', 'exclude: [lib/core/]'),
    );
    await File('${root.path}/lib/core/private.dart')
        .writeAsString('part of named_app;');
    final dependency = await Directory.systemTemp.createTemp(
      'archway-dart-dependency-',
    );
    addTearDown(() => dependency.delete(recursive: true));
    await File('${dependency.path}/other.dart').writeAsString(
      "library named_app; part '${File('${root.path}/lib/core/private.dart').uri}';",
    );
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(await configFile.readAsString()) as Map;
    (config['packages'] as List).add({
      'name': 'other',
      'rootUri': dependency.uri.toString(),
      'packageUri': './',
      'languageVersion': '3.13',
    });
    await configFile.writeAsString(jsonEncode(config));
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(
      (report.payload['violations'] as List).single['code'],
      'LOCAL_TARGET_EXCLUDED',
    );
    expect(
      (report.payload['unknowns'] as List).map((d) => d['code']),
      contains('DART_PART_OWNER_UNPROVEN'),
    );
    expect((report.payload['input_identity'] as Map)['rechecked'], true);
  });

  test(
    'a physical part cannot masquerade as a standalone imported library',
    () async {
      final root = await dartFixture();
      await File('${root.path}/lib/core/api.dart')
          .writeAsString("part 'private.dart';");
      await File('${root.path}/lib/core/private.dart')
          .writeAsString("part of 'api.dart'; class Thing {}");
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['unknowns'] as List).map((d) => d['code']),
        contains('UNRESOLVED_IMPORT'),
      );
      final import = ((report.payload['facts'] as Map)['edges'] as List).first;
      expect(import['resolution'], {'kind': 'unresolved'});
    },
  );

  test(
    'an empty prepared package map cannot certify a declared Dart package',
    () async {
      final root = await dartFixture();
      await File('${root.path}/.dart_tool/package_config.json')
          .writeAsString('{"configVersion":2,"packages":[]}');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['tool_errors'] as List).map((d) => d['code']),
        contains('DART_ANALYSIS_FAILED'),
      );
      expect(
        (report.payload['coverage'] as Map)['files'],
        everyElement(containsPair('assignment', 'failed')),
      );
    },
  );

  test('unsupported package language versions cannot silently use the pinned parser', () async {
    final root = await dartFixture();
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(await configFile.readAsString()) as Map;
    config['packages'][0]['languageVersion'] = '3.14';
    await configFile.writeAsString(jsonEncode(config));
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(report.payload['analysis_complete'], false);
  });

  test(
    'a per-file language override cannot exceed its prepared package version',
    () async {
      final root = await dartFixture(
        main: "// @dart=3.13\nimport '../core/private.dart';\n",
      );
      final configFile = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await configFile.readAsString()) as Map;
      config['packages'][0]['languageVersion'] = '3.12';
      await configFile.writeAsString(jsonEncode(config));
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );
  test('explicit SDK imports use verified physical SDK provenance without synthetic edges', () async {
    final root = await dartFixture(main: "import 'dart:io';\n");
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok');
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.single['resolution'], {
      'kind': 'builtin',
      'identity': 'dart:io',
    });
    expect(report.payload['observed'], {
      'files': 2,
      'analyzed_files': 2,
      'edges': 1,
    });
  });
}

const dartPolicy = '''
version: 1
projects:
  - id: app
    adapter: dart
    package_roots: [./]
scope: [lib/]
exclude: []
nodes:
  - id: app
    responsibility: Application
    owns: [lib/app/]
    allows: []
    public: []
  - id: core
    responsibility: Core
    owns: [lib/core/]
    allows: []
    public: []
''';

Future<Directory> dartFixture({String? main, String? policy}) async {
  final root = await Directory.systemTemp.createTemp('archway-dart-');
  addTearDown(() => root.delete(recursive: true));
  await Directory('${root.path}/lib/app').create(recursive: true);
  await Directory('${root.path}/lib/core').create(recursive: true);
  await Directory('${root.path}/.dart_tool').create();
  await File('${root.path}/architecture.yaml')
      .writeAsString(policy ?? dartPolicy);
  await File('${root.path}/pubspec.yaml')
      .writeAsString('name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n');
  await File('${root.path}/.dart_tool/package_config.json').writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'fixture',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.13',
        },
      ],
      'generator': 'pub',
      'generatorVersion': '3.13.3',
    }),
  );
  await File('${root.path}/lib/app/main.dart')
      .writeAsString(main ?? "import '../core/private.dart';\n");
  await File('${root.path}/lib/core/private.dart')
      .writeAsString('class Thing {}\n');
  return root;
}
