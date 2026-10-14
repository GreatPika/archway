import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture, dartPolicy;

void main() {
  test('plugin-dependent analysis options remain incomplete', () async {
    final root = await dartFixture();
    await File('${root.path}/analysis_options.yaml').writeAsString(
      'plugins:\n  custom_analyzer:\n    path: tools/custom_analyzer\n',
    );
    final out = StringBuffer(), err = StringBuffer();
    final exit = await CLI().run([
      '--root',
      root.path,
      'check',
    ], CliStreams(out, err));
    final report = jsonDecode(out.toString()) as Map;
    expect(exit, 2);
    expect(report['status'], 'incomplete');
    expect(report['payload']['analysis_complete'], false);
    expect(report['payload']['input_identity']['rechecked'], true);
    expect(err.toString(), '');
    expect(out.toString().split('\n'), hasLength(2));
  });
  test(
    'shared workspace configuration validates every declared package mapping',
    () async {
      final root = await dartFixture(
        main: 'class App {}',
        policy: dartPolicy.replaceFirst(
          'package_roots: [./]',
          'package_roots: [lib/app, lib/core]',
        ),
      );
      // A common package map is valid only if each declared package/path is
      // configured. One root's entry must not vouch for its unmapped sibling.
      final config = File('${root.path}/.dart_tool/package_config.json');
      await config.writeAsString(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'app',
              'rootUri': '../lib/app/',
              'packageUri': './',
              'languageVersion': '3.13',
            },
          ],
        }),
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['analysis_complete'], false);
      expect((report.payload['coverage'] as Map)['files'], hasLength(2));
    },
  );
  test('prepared pub workspaces use their common config and retain generated sources', () async {
    final root = await workspaceFixture();
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'negative', reason: jsonEncode(report.payload));
    expect(report.payload['analysis_complete'], true);
    expect(report.payload['observed'], {
      'files': 2,
      'analyzed_files': 2,
      'edges': 1,
    });
    final contexts =
        ((report.payload['coverage'] as Map)['projects'] as List)
                .single['contexts']
            as List;
    expect(contexts, hasLength(1));
    expect(
      contexts.single['context_id'],
      'dart:workspace:8852675619d5013923329f21f95857a24ffff10d47f45666729972a451a382c8',
    );
    expect(contexts.single['descriptor'], {
      'excluded_paths': [],
      'included_paths': ['packages/app', 'packages/core'],
      'options_paths': [],
      'package_config_path': '.dart_tool/package_config.json',
      'root': './',
      'sdk_version': '3.13.3',
    });
  });
  test(
    'a stale common workspace map cannot borrow the container package identity',
    () async {
      final root = await workspaceFixture();
      final config = File('${root.path}/.dart_tool/package_config.json');
      final content = jsonDecode(await config.readAsString()) as Map;
      (content['packages'] as List).removeWhere(
        (entry) => entry['name'] == 'core',
      );
      await config.writeAsString(jsonEncode(content));
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['analysis_complete'], false);
    },
  );

  test('overlapping declared projects retain all workspace candidates without precedence', () async {
    final root = await workspaceFixture();
    final policy = File('${root.path}/architecture.yaml');
    await policy.writeAsString(
      (await policy.readAsString()).replaceFirst(
        'scope:',
        '  - {id: duplicate, adapter: dart, package_roots: [packages/app]}\nscope:',
      ),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final rows = (report.payload['coverage'] as Map)['files'] as List;
    expect(rows.first['assignment'], 'ambiguous');
    expect(rows.first['candidates'].map((c) => c['project_id']), [
      'duplicate',
      'workspace',
    ]);
    expect(rows.last['assignment'], 'assigned');
    expect(rows, hasLength(2));
  });

  test('unfinished peer discovery retains independent workspace candidates and facts', () async {
    final root = await workspaceFixture();
    await Directory('${root.path}/broken/.dart_tool').create(recursive: true);
    await File('${root.path}/broken/.dart_tool/package_config.json')
        .writeAsString('{}');
    final policy = File('${root.path}/architecture.yaml');
    await policy.writeAsString(
      (await policy.readAsString()).replaceFirst(
        'scope:',
        '  - {id: broken, adapter: dart, package_roots: [broken]}\nscope:',
      ),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final rows = (report.payload['coverage'] as Map)['files'] as List;
    expect(rows, hasLength(2));
    expect(
      rows.every(
        (r) => r['assignment'] == 'failed' && r['discovery_complete'] == false,
      ),
      true,
    );
    expect(
      rows.every((r) => r['candidates'].single['project_id'] == 'workspace'),
      true,
    );
    expect(
      rows.every((r) => r['unresolved_project_ids'].single == 'broken'),
      true,
    );
    expect(
      (report.payload['violations'] as List).single['code'],
      'DEPENDENCY_NOT_ALLOWED',
    );
  });

  test('a custom embedder cannot relabel an ordinary SDK file as dart:ui', () async {
    final root = await dartFixture(main: "import 'dart:ui';");
    final sdk = Directory(Platform.resolvedExecutable).parent.parent.path;
    final core = jsonEncode(File('$sdk/lib/core/core.dart').path);
    await Directory('${root.path}/fake/lib').create(recursive: true);
    await File('${root.path}/fake/lib/_embedder.yaml').writeAsString(
      'embedded_libs:\n  "dart:core": $core\n  "dart:ui": $core\n',
    );
    final file = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(await file.readAsString()) as Map;
    (config['packages'] as List).add({
      'name': 'sky_engine',
      'rootUri': '../fake/',
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });
    await file.writeAsString(jsonEncode(config));
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(
      ((report.payload['facts'] as Map)['edges'] as List).single['resolution'],
      {'kind': 'unresolved'},
    );
  });

  test('URI parts cannot choose between conflicting context-specific package owners', () async {
    final root = await dartFixture(
      policy: dartPolicy.replaceFirst(
        'package_roots: [./]',
        'package_roots: [lib/app, lib/core]',
      ),
    );
    final part = File('${root.path}/lib/core/private.dart');
    await part.writeAsString("part of 'package:owner/main.dart';");
    for (final name in ['app', 'core']) {
      await Directory('${root.path}/lib/$name/.dart_tool').create();
      await File('${root.path}/lib/$name/.dart_tool/package_config.json')
          .writeAsString(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'owner',
                  'rootUri': '../',
                  'packageUri': './',
                  'languageVersion': '3.13',
                },
              ],
            }),
          );
      await File('${root.path}/lib/$name/main.dart')
          .writeAsString("part '${part.uri}';");
    }
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.singleWhere((e) => e['kind'] == 'part_of')['resolution'], {
      'kind': 'unresolved',
    });
    expect(
      (report.payload['unknowns'] as List).map((u) => u['code']),
      contains('DART_PART_OWNER_UNPROVEN'),
    );
  });
}

Future<Directory> workspaceFixture() async {
  final root = await Directory.systemTemp.createTemp('archway-workspace-');
  addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/pubspec.yaml').writeAsString('''
name: workspace_root
environment:
  sdk: ^3.13.0
workspace: [packages/app, packages/core]
''');
  for (final name in ['app', 'core']) {
    await Directory('${root.path}/packages/$name/lib').create(recursive: true);
    await File('${root.path}/packages/$name/pubspec.yaml').writeAsString('''
name: $name
resolution: workspace
environment:
  sdk: ^3.13.0
''');
  }
  await File('${root.path}/architecture.yaml').writeAsString('''
version: 1
projects:
  - id: workspace
    adapter: dart
    package_roots: [packages/app, packages/core]
scope: [packages/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [packages/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [packages/core/], allows: [], public: []}
''');
  await File('${root.path}/packages/app/lib/main.dart').writeAsString(
    "import '${File('${root.path}/packages/core/lib/value.g.dart').uri}';",
  );
  await File('${root.path}/packages/core/lib/value.g.dart')
      .writeAsString('class Value {}');
  final prepared = await Process.run(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'pub',
    'get',
    '--offline',
  ], workingDirectory: root.path);
  expect(
    prepared.exitCode,
    0,
    reason: '${prepared.stdout}\n${prepared.stderr}',
  );
  return root;
}
