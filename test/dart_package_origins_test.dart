import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture;
import 'dart_workspace_test.dart' show workspaceFixture;

void main() {
  test(
    'self package identity remains local without an ordinary lock',
    () async {
      final root = await dartFixture(
        main: "import 'package:fixture/core/private.dart';",
      );
      final out = StringBuffer(), err = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'check',
      ], CliStreams(out, err));
      final report = jsonDecode(out.toString()) as Map;
      expect(exit, 1, reason: out.toString());
      expect(err.toString(), '');
      expect(out.toString().split('\n'), hasLength(2));
      expect(report['status'], 'negative');
      expect(report['payload']['analysis_complete'], true);
      expect(
        report['payload']['facts']['edges'].single['resolution']['kind'],
        'local',
      );
      expect(
        report['payload']['violations'].single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
      expect(report['payload']['input_identity']['rechecked'], true);
    },
  );
  test('real hosted instance outside root is external', () async {
    final root = await hostedFixture();
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok', reason: jsonEncode(report.payload));
    expect(report.payload['analysis_complete'], true);
    expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
      'kind': 'external',
      'identity': 'package:collection/collection.dart',
    });
    final inputs = (report.payload['input_identity'] as Map)['inputs'] as List;
    expect(inputs.any((i) => i['location']['path'] == 'pubspec.lock'), true);
  });
  test('hosted instance inside broad ownership remains external through a relative URI', () async {
    final root = await hostedFixture();
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(await configFile.readAsString()) as Map;
    final entry = (config['packages'] as List).singleWhere(
      (e) => e['name'] == 'collection',
    );
    final original = Directory(Uri.parse(entry['rootUri']).toFilePath());
    final copied = Directory('${root.path}/lib/app/vendor/collection');
    await copyTree(original, copied);
    // Installed sources are real; their development-only lints are outside
    // this fixture's prepared dependency closure.
    for (final entity in copied.listSync(recursive: true)) {
      if (entity is File && entity.uri.pathSegments.last == 'analysis_options.yaml') {
        await entity.writeAsString('{}');
      }
    }
    entry['rootUri'] = '../lib/app/vendor/collection/';
    final policy = File('${root.path}/architecture.yaml');
    await policy.writeAsString(
      (await policy.readAsString()).replaceFirst(
        'exclude: []',
        'exclude: [lib/app/vendor/]',
      ),
    );
    await configFile.writeAsString(jsonEncode(config));
    await File('${root.path}/lib/app/main.dart')
        .writeAsString("import 'vendor/collection/lib/collection.dart';");
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok', reason: jsonEncode(report.payload));
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    final app = edges.singleWhere((e) => e['source'] == 'lib/app/main.dart');
    expect(app['resolution']['kind'], 'external');
    expect(report.payload['violations'], isEmpty);
  });

  test(
    'real pub workspace membership wins over hosted-looking constraints',
    () async {
      final root = await workspaceFixture();
      final app = File('${root.path}/packages/app/pubspec.yaml');
      await app.writeAsString(
        '${await app.readAsString()}dependencies:\n  core: ^1.0.0\n',
      );
      final core = File('${root.path}/packages/core/pubspec.yaml');
      await core.writeAsString('${await core.readAsString()}version: 1.0.0\n');
      await File('${root.path}/packages/app/lib/main.dart')
          .writeAsString("import 'package:core/value.g.dart';");
      await prepare(root);
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative', reason: jsonEncode(report.payload));
      expect(report.payload['analysis_complete'], true);
      expect(
        (report.payload['facts'] as Map)['edges'].single['resolution']['kind'],
        'local',
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );

  test('effective local override cannot be relabeled by stale hosted lock metadata', () async {
    final root = await hostedFixture();
    await File('${root.path}/pubspec_overrides.yaml').writeAsString(
      'dependency_overrides:\n  collection:\n    path: ../different-collection\n',
    );
    await File('${root.path}/lib/app/main.dart').writeAsString(
      "import 'package:collection/collection.dart'; import '../core/private.dart'; import 'dart:io';",
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.map((e) => e['resolution']['kind']), [
      'unresolved',
      'local',
      'builtin',
    ]);
    expect(
      (report.payload['violations'] as List).single['code'],
      'DEPENDENCY_NOT_ALLOWED',
    );
  });

  test(
    'real pub path package outside root remains a known local violation',
    () async {
      final root = await pathFixture();
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative', reason: jsonEncode(report.payload));
      expect(report.payload['analysis_complete'], true);
      final edge = (report.payload['facts'] as Map)['edges'].single;
      expect(edge['resolution']['kind'], 'local');
      expect(edge['resolution']['path'], isNull);
      expect(
        (report.payload['violations'] as List).single['code'],
        'LOCAL_TARGET_OUTSIDE_SCOPE',
      );
    },
  );
  test(
    'real remote Git checkout joins pinned commit and package subpath',
    () async {
      final root = await gitFixture();
      // Pub's package subpath remains slash-separated metadata on every host.
      expect(
        await File('${root.path}/pubspec.lock').readAsString(),
        contains('path: "pkgs/path"'),
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'ok', reason: jsonEncode(report.payload));
      expect((report.payload['facts'] as Map)['edges'].single['resolution'], {
        'kind': 'external',
        'identity': 'package:path/path.dart',
      });
    },
    skip: Platform.environment['ARCHWAY_PUB_GIT_FIXTURE'] == null
        ? 'Requires maintainer-prepared official Git fixture.'
        : false,
  );
}

Future<Directory> hostedFixture() async {
  final root = await dartFixture(
    main: "import 'package:collection/collection.dart';",
  );
  final spec = File('${root.path}/pubspec.yaml');
  await spec.writeAsString(
    '${await spec.readAsString()}dependencies:\n  collection: 1.19.1\n',
  );
  await prepare(root);
  return root;
}

Future<void> prepare(Directory root) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'pub',
    'get',
    '--offline',
  ], workingDirectory: root.path);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

Future<void> copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  for (final entity in source.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((p) => p.isNotEmpty).last;
    final destination = '${target.path}/$name';
    if (entity is Link) {
      await Link(destination).create(await entity.target());
    } else if (entity is Directory) {
      await copyTree(entity, Directory(destination));
    } else if (entity is File) {
      await entity.copy(destination);
    }
  }
}

Future<Directory> pathFixture() async {
  final root = await dartFixture(
    main: "import 'package:outside_pkg/value.dart';",
  );
  final dependency = await Directory.systemTemp.createTemp('archway-pub-path-');
  addTearDown(() => dependency.delete(recursive: true));
  await Directory('${dependency.path}/lib').create();
  await File('${dependency.path}/pubspec.yaml').writeAsString(
    'name: outside_pkg\nversion: 1.2.3\nenvironment:\n  sdk: ^3.13.0\n',
  );
  await File('${dependency.path}/lib/value.dart')
      .writeAsString('class Value {}');
  final spec = File('${root.path}/pubspec.yaml');
  final basename = dependency.uri.pathSegments.where((p) => p.isNotEmpty).last;
  await spec.writeAsString(
    '${await spec.readAsString()}dependencies:\n  outside_pkg:\n    path: ../$basename\n',
  );
  await prepare(root);
  return root;
}

Future<Directory> gitFixture() async {
  final root = await dartFixture(main: "import 'package:path/path.dart';");
  final prepared = Platform.environment['ARCHWAY_PUB_GIT_FIXTURE']!;
  for (final name in [
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
  ]) {
    await File('$prepared/$name').copy('${root.path}/$name');
  }
  return root;
}
