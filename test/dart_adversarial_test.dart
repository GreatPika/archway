import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture, dartPolicy;

void main() {
  for (final alias in [false, true]) {
    test(
      'a ${alias ? "directory alias" : "directory"} at selected analysis options cannot become absent configuration',
      () async {
        final root = await dartFixture();
        final options = '${root.path}/analysis_options.yaml';
        if (alias) {
          final directory = await Directory('${root.path}/options-directory')
              .create();
          await Link(options).create(directory.path);
        } else {
          await Directory(options).create();
        }
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        expect(report.payload['analysis_complete'], false);
        expect(
          report.payload['tool_errors'],
          contains(
            allOf(
              containsPair('code', 'DART_ANALYSIS_FAILED'),
              containsPair(
                'message',
                contains('Analyzer input is not a regular file'),
              ),
            ),
          ),
        );
      },
    );
  }

  test('compiler target spellings outside the canonical path contract stay unresolved', () async {
    final root = await dartFixture(
      main: "import '../ignored/bad[1].dart';",
      policy: dartPolicy.replaceFirst('exclude: []', 'exclude: [lib/ignored/]'),
    );
    await Directory('${root.path}/lib/ignored').create();
    await File('${root.path}/lib/ignored/bad[1].dart')
        .writeAsString('class Thing {}');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(
      ((report.payload['facts'] as Map)['edges'] as List).single['resolution'],
      {'kind': 'unresolved'},
    );
  });
  test('unreadable selected analysis options cannot become an absent clean configuration', () async {
    final root = await dartFixture();
    final options = File('${root.path}/analysis_options.yaml');
    await options.writeAsString(
      'analyzer:\n  language:\n    strict-casts: true\n',
    );
    final chmod = await Process.run('/bin/chmod', ['000', options.path]);
    expect(chmod.exitCode, 0);
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(report.payload['analysis_complete'], false);
  }, skip: !Platform.isLinux);

  test(
    'duplicate prepared package mappings cannot recover into a clean fallback',
    () async {
      final root = await dartFixture();
      final file = File('${root.path}/.dart_tool/package_config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      (config['packages'] as List).add(Map.from(config['packages'][0] as Map));
      await file.writeAsString(jsonEncode(config));
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['analysis_complete'], false);
    },
  );

  test('named part owners outside the portable path contract cannot crash inspection', () async {
    final root = await dartFixture(
      main: 'class App {}',
      policy: dartPolicy.replaceFirst('exclude: []', 'exclude: [lib/ignored/]'),
    );
    await File('${root.path}/lib/core/private.dart')
        .writeAsString('part of named_bad;');
    await Directory('${root.path}/lib/ignored').create();
    await File('${root.path}/lib/ignored/bad[1].dart')
        .writeAsString("library named_bad; part '../core/private.dart';");
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(
      ((report.payload['facts'] as Map)['edges'] as List).single['resolution'],
      {'kind': 'unresolved'},
    );
  });

  test(
    'experimental analysis flags remain outside the supported Dart envelope',
    () async {
      final root = await dartFixture();
      await File('${root.path}/analysis_options.yaml')
          .writeAsString('analyzer:\n  enable-experiment: [enhanced-parts]\n');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['analysis_complete'], false);
    },
  );
  test('nonexistent Dart 2 per-file versions remain incomplete and retain known boundaries', () async {
    for (final version in ['2.20', '2.99']) {
      final root = await dartFixture(
        main: "// @dart=$version\nimport '../core/private.dart';\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(
        report.status,
        'incomplete',
        reason: 'per-file Dart $version is not a stable release',
      );
      expect(report.exitCode, 2);
      expect(report.payload['analysis_complete'], false);
      expect(
        (report.payload['unknowns'] as List).map((d) => d['code']),
        contains('UNSUPPORTED_ANALYSIS_CONFIGURATION'),
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    }
    final supported = await dartFixture(
      main: "// @dart=2.19\nimport '../core/private.dart';\n",
    );
    final report = await Inspection().check(
      RepositorySelection(supported.path),
    );
    expect(report.status, 'negative');
    expect(report.payload['analysis_complete'], true);
  });

  for (final kind in ['ordinary', 'fifo', 'socket']) {
    test(
      'a stable $kind entry outside scope does not change inventory identity',
      () async {
        final root = await dartFixture(main: 'class App {}');
        final path = '${root.path}/unrelated.$kind';
        if (kind == 'ordinary') {
          await File(path).writeAsString('Unrelated data');
        } else if (kind == 'fifo') {
          final result = await Process.run('/usr/bin/mkfifo', [path]);
          expect(result.exitCode, 0);
        } else {
          try {
            final socket = await ServerSocket.bind(
              InternetAddress(path, type: InternetAddressType.unix),
              0,
            );
            addTearDown(socket.close);
          } on SocketException catch (error) {
            if (error.osError?.errorCode != 9) rethrow;
            markTestSkipped(
              'Host refuses Unix-domain server socket binding (errno 9).',
            );
            return;
          }
        }
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(
          report.status,
          'ok',
          reason:
              'A stable $kind entry must retain the same inventory identity',
        );
        expect(report.payload['analysis_complete'], true);
        expect(
          (report.payload['input_identity'] as Map)['changed_inputs'],
          isEmpty,
        );
        expect((report.payload['input_identity'] as Map)['rechecked'], true);
      },
      skip: !Platform.isLinux,
    );
  }
}
