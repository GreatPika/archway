import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartPolicy;

// This suite uses a real, separately prepared Flutter project. Preparation may
// fetch dependencies; Inspection.check and CLI.run below never prepare it.
final prepared = Platform.environment['ARCHWAY_FLUTTER_FIXTURE'];

void main() {
  test(
    'verified Flutter SDK package and dart:ui mappings produce builtin facts',
    () async {
      final root = await flutterFixture(
        "import 'package:flutter/foundation.dart';\nimport 'dart:ui';\n",
      );
      final out = StringBuffer(), err = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'check',
      ], CliStreams(out, err));
      final report = jsonDecode(out.toString()) as Map;
      expect(exit, 0, reason: jsonEncode(report['payload']));
      expect(report['status'], 'ok');
      expect(report['payload']['analysis_complete'], true);
      expect(report['payload']['facts']['edges'].map((e) => e['resolution']), [
        {'kind': 'builtin', 'identity': 'package:flutter/foundation.dart'},
        {'kind': 'builtin', 'identity': 'dart:ui'},
      ]);
      expect(report['tool_versions']['dart_sdk'], '3.13.3');
      expect(report['payload']['input_identity']['rechecked'], true);
      expect(err.toString(), '');
      expect(out.toString().split('\n'), hasLength(2));
    },
    skip: prepared == null
        ? 'Set ARCHWAY_FLUTTER_FIXTURE to a real prepared compatible Flutter project.'
        : false,
  );
  test(
    'real Flutter URI parts and generated Dart sources retain physical ownership',
    () async {
      final root = await flutterFixture(
        "library app; import 'package:flutter/foundation.dart'; import 'dart:ui'; import '../core/value.g.dart'; part 'part.g.dart';",
      );
      await File('${root.path}/lib/app/part.g.dart')
          .writeAsString("part of 'main.dart'; class Part {}");
      await File('${root.path}/lib/core/value.g.dart')
          .writeAsString('class Generated {}');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(
        report.status,
        'negative',
        reason: jsonEncode({
          'unknowns': report.payload['unknowns'],
          'errors': report.payload['tool_errors'],
        }),
      );
      expect(report.payload['analysis_complete'], true);
      expect(report.payload['observed'], {
        'files': 4,
        'analyzed_files': 4,
        'edges': 5,
      });
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
    skip: prepared == null ? 'Requires prepared Flutter fixture.' : false,
    timeout: Timeout(Duration(minutes: 4)),
  );

  test('unrelated missing installed metadata does not poison verified Flutter references', () async {
    final root = await flutterFixture(
      "import 'package:flutter/foundation.dart'; import 'dart:ui';",
    );
    final file = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(await file.readAsString()) as Map;
    (config['packages'] as List).insert(0, {
      'name': 'missing_dependency',
      'rootUri': '../absent/',
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });
    await file.writeAsString(jsonEncode(config));
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'ok', reason: jsonEncode(report.payload['unknowns']));
  }, skip: prepared == null ? 'Requires prepared Flutter fixture.' : false);

  test(
    'a misleading SDK package mapping stays unresolved beside genuine dart:ui',
    () async {
      final root = await flutterFixture(
        "import 'package:flutter/foundation.dart'; import 'dart:ui'; import '../core/private.dart';",
      );
      await Directory('${root.path}/fake/lib').create(recursive: true);
      await File('${root.path}/fake/pubspec.yaml')
          .writeAsString('name: flutter');
      await File('${root.path}/fake/lib/foundation.dart')
          .writeAsString('class Fake {}');
      final configFile = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await configFile.readAsString()) as Map;
      (config['packages'] as List).singleWhere(
        (e) => e['name'] == 'flutter',
      )['rootUri'] = '../fake/';
      await configFile.writeAsString(jsonEncode(config));
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      expect(edges.map((e) => e['resolution']['kind']), [
        'unresolved',
        'builtin',
        'local',
      ]);
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
    skip: prepared == null ? 'Requires prepared Flutter fixture.' : false,
  );

  test(
    'contradictory package origin affects that Flutter reference only',
    () async {
      final root = await flutterFixture(
        "import 'package:flutter/foundation.dart'; import 'dart:ui';",
      );
      await File('${root.path}/pubspec.lock').writeAsString(
        'packages:\n  flutter:\n    source: hosted\n    description: flutter\n    version: "0.0.0"\n',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        ((report.payload['facts'] as Map)['edges'] as List).map(
          (e) => e['resolution']['kind'],
        ),
        ['unresolved', 'builtin'],
      );
    },
    skip: prepared == null ? 'Requires prepared Flutter fixture.' : false,
  );

  test('independent SDK mappings suffice without a lock and generated absence stays incomplete', () async {
    final root = await flutterFixture(
      "import 'package:flutter/foundation.dart'; import 'dart:ui'; import '../core/missing.g.dart';",
    );
    await File('${root.path}/pubspec.lock').delete();
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(
      ((report.payload['facts'] as Map)['edges'] as List).map(
        (e) => e['resolution']['kind'],
      ),
      ['builtin', 'builtin', 'unresolved'],
    );
    expect((report.payload['input_identity'] as Map)['rechecked'], true);
  }, skip: prepared == null ? 'Requires prepared Flutter fixture.' : false);

  test('Flutter bin on PATH follows the platform runtime contract', () async {
    final root = await flutterFixture(
      "import 'package:flutter_test/flutter_test.dart'; import 'dart:ui';",
    );
    final config = jsonDecode(
      await File('${root.path}/.dart_tool/package_config.json').readAsString(),
    ) as Map;
    final flutterRoot = Uri.parse(config['flutterRoot'] as String).toFilePath();
    final process = await Process.run(
      Platform.resolvedExecutable,
      [
        '--suppress-analytics',
        'run',
        'bin/archway.dart',
        '--root',
        root.path,
        'check',
      ],
      environment: {'PATH': '$flutterRoot/bin'},
    );
    expect(process.stderr, '');
    final report = jsonDecode(process.stdout as String) as Map;
    if (Platform.isWindows) {
      // Flutter/bin only provides dart.bat on Windows. The supported route
      // selects bin/cache/dart-sdk/bin; inspection never executes a launcher.
      expect(process.exitCode, 2, reason: '${process.stdout}');
      expect(report['status'], 'incomplete');
      expect(report['payload']['analysis_complete'], false);
      expect(
        (report['payload']['tool_errors'] as List).map((e) => e['code']),
        contains('DART_SDK_UNAVAILABLE'),
      );
      return;
    }
    expect(process.exitCode, 0, reason: '${process.stdout}');
    expect(report['payload']['analysis_complete'], true);
    expect(
      report['payload']['facts']['edges'].map((e) => e['resolution']['kind']),
      ['builtin', 'builtin'],
    );
  }, skip: prepared == null ? 'Requires prepared Flutter fixture.' : false);
  test(
    'named Flutter parts stay incomplete when shipped SDK internals leave discovery gaps',
    () async {
      final root = await flutterFixture(
        "library named; import 'dart:ui'; import '../core/private.dart'; part 'part.g.dart';",
      );
      await File('${root.path}/lib/app/part.g.dart')
          .writeAsString('part of named; class Part {}');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['analysis_complete'], false);
      expect(
        (report.payload['unknowns'] as List).map((u) => u['code']),
        contains('DART_PART_OWNER_UNPROVEN'),
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
    skip: prepared == null ? 'Requires prepared Flutter fixture.' : false,
    timeout: Timeout(Duration(minutes: 4)),
  );
}

Future<Directory> flutterFixture(String main) async {
  final root = await Directory.systemTemp.createTemp('archway-flutter-');
  addTearDown(() => root.delete(recursive: true));
  for (final path in ['.dart_tool', 'lib/app', 'lib/core']) {
    await Directory('${root.path}/$path').create(recursive: true);
  }
  for (final path in [
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
  ]) {
    await File('$prepared/$path').copy('${root.path}/$path');
  }
  await File('${root.path}/architecture.yaml').writeAsString(dartPolicy);
  await File('${root.path}/lib/app/main.dart').writeAsString(main);
  await File('${root.path}/lib/core/private.dart')
      .writeAsString('class Value {}');
  return root;
}
