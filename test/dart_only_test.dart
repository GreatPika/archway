import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/policy_definition.dart';
import 'package:archway/src/plan/policy_loader.dart';
import 'package:test/test.dart';

void main() {
  test('init defaults to Dart without requiring a template option', () async {
    final root = await fixture(scope: []);
    await File('${root.path}/architecture.yaml').delete();
    final stdout = StringBuffer(), stderr = StringBuffer();
    final code = await CLI().run([
      '--root',
      root.path,
      'init',
      '--dry-run',
    ], CliStreams(stdout, stderr));
    expect(code, 0);
    expect(stderr.toString(), isEmpty);
    final result = jsonDecode(stdout.toString()) as Map;
    expect(result['payload']['template'], 'dart');
    expect(result['payload']['outcome'], 'planned');
    expect(await root.list().length, 0);
  });

  for (final template in ['typescript', 'mixed']) {
    test(
      'init rejects unsupported $template template without writes',
      () async {
        final root = await fixture(scope: []);
        await File('${root.path}/architecture.yaml').delete();
        final stdout = StringBuffer(), stderr = StringBuffer();
        final code = await CLI().run([
          '--root',
          root.path,
          'init',
          '--template',
          template,
          '--dry-run',
        ], CliStreams(stdout, stderr));
        expect(code, 64);
        expect(await root.list().length, 0);
      },
    );
  }

  test(
    'TypeScript policy declaration is rejected at its adapter pointer',
    () async {
      final root = await fixture(
        scope: [],
        projects: [
          {'id': 'web', 'adapter': 'typescript', 'tsconfig': 'tsconfig.json'},
        ],
      );
      final result = await loadPlan(RepositorySelection(root.path));
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.rulePointer, '/projects/0/adapter');
    },
  );

  test(
    'directory corpus includes Dart but ignores incidental JS and TS files',
    () async {
      final root = await fixture(scope: ['src/']);
      await Directory('${root.path}/src').create();
      for (final file in ['main.dart', 'build.js', 'tools.ts']) {
        await File('${root.path}/src/$file').writeAsString('');
      }
      final report = await Inspection().check(RepositorySelection(root.path));
      expect((report.payload['observed'] as Map)['files'], 1);
      final coverage = report.payload['coverage'] as Map;
      expect((coverage['files'] as List).map((f) => f['path']), [
        'src/main.dart',
      ]);
      expect(report.toolVersions['node'], isNull);
      expect(report.toolVersions['typescript'], isNull);
      expect(report.toolVersions['typescript_adapter'], isNull);
    },
  );

  test(
    'explicit non-Dart file scope is surfaced as unsupported warning',
    () async {
      final root = await fixture(scope: ['tools.ts']);
      await File('${root.path}/tools.ts').writeAsString('');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect((report.payload['observed'] as Map)['files'], 0);
      expect(
        (report.payload['warnings'] as List).map((w) => w['code']),
        contains('UNSUPPORTED_SCOPE_FILE'),
      );
    },
  );
}

Future<Directory> fixture({
  required List<String> scope,
  List<Map<String, Object>> projects = const [],
}) async {
  final root = await Directory.systemTemp.createTemp('archway-dart-only-');
  addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/architecture.yaml').writeAsString(
    jsonEncode({
      'version': 1,
      'projects': projects,
      'scope': scope,
      'exclude': [],
      'nodes': [],
    }),
  );
  return root;
}
