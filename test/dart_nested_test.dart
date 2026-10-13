import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture, dartPolicy;

void main() {
  test('real nested packages split overlapping declared roots using actual option mappings', () async {
    final root = await dartFixture(
      main: 'class App {}',
      policy: dartPolicy.replaceFirst(
        'package_roots: [./]',
        'package_roots: [./, lib/core/nested]',
      ),
    );
    final nested = Directory('${root.path}/lib/core/nested');
    await nested.create(recursive: true);
    await File('${nested.path}/pubspec.yaml')
        .writeAsString('name: nested\nenvironment:\n  sdk: ^3.13.0\n');
    await File('${nested.path}/value.g.dart')
        .writeAsString('class Generated {}');
    await File('${root.path}/shared.yaml')
        .writeAsString('analyzer:\n  language:\n    strict-casts: true\n');
    await File('${root.path}/analysis_options.yaml')
        .writeAsString('include: shared.yaml\n');
    await File('${nested.path}/analysis_options.yaml')
        .writeAsString('include: ../../../shared.yaml\n');
    final prepared = await Process.run(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'pub',
      'get',
      '--offline',
    ], workingDirectory: nested.path);
    expect(
      prepared.exitCode,
      0,
      reason: '${prepared.stdout}\n${prepared.stderr}',
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(
      report.status,
      'ok',
      reason: jsonEncode(report.payload['tool_errors']),
    );
    expect(report.payload['analysis_complete'], true);
    expect(report.payload['observed'], {
      'files': 3,
      'analyzed_files': 3,
      'edges': 0,
    });
    final contexts =
        ((report.payload['coverage'] as Map)['projects'] as List)
                .single['contexts']
            as List;
    expect(contexts, hasLength(2));
    final outer = contexts.singleWhere((c) => c['descriptor']['root'] == './');
    final inner = contexts.singleWhere(
      (c) => c['descriptor']['root'] == 'lib/core/nested',
    );
    expect(
      outer['context_id'],
      'dart:app:8e73418303168fa39619cd7a19a3c8cb5feb7445f7202f5b538085bf7c977658',
    );
    expect(
      inner['context_id'],
      'dart:app:8f138ea7bd95d61923c919ad61d26b0d9309e6dc078e6afc1fa4579bf5957113',
    );
    expect(outer['descriptor'], {
      'excluded_paths': ['lib/core/nested'],
      'included_paths': ['./'],
      'options_paths': ['analysis_options.yaml', 'shared.yaml'],
      'package_config_path': '.dart_tool/package_config.json',
      'root': './',
      'sdk_version': '3.13.3',
    });
    expect(inner['descriptor'], {
      'excluded_paths': [],
      'included_paths': ['lib/core/nested'],
      'options_paths': ['lib/core/nested/analysis_options.yaml', 'shared.yaml'],
      'package_config_path': 'lib/core/nested/.dart_tool/package_config.json',
      'root': 'lib/core/nested',
      'sdk_version': '3.13.3',
    });
  });
}
