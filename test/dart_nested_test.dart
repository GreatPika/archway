import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/policy_definition.dart';
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
      'dart:app:f99108d04fd0551960b0028c1e850a740467e1381d64f9369d441d5eee699913',
    );
    expect(
      inner['context_id'],
      'dart:app:5d4663814b076f3564e964d1060c1c45ebb2b8b9e162e2ac4a0fc6ebe48168b0',
    );
    expect(outer['descriptor'], {
      'excluded_paths': ['lib/core/nested'],
      'included_paths': ['./'],
      'options_paths': ['analysis_options.yaml', 'shared.yaml'],
      'package_config_path': '.dart_tool/package_config.json',
      'root': './',
      'sdk_version': '3.13.5',
    });
    expect(inner['descriptor'], {
      'excluded_paths': [],
      'included_paths': ['lib/core/nested'],
      'options_paths': ['lib/core/nested/analysis_options.yaml', 'shared.yaml'],
      'package_config_path': 'lib/core/nested/.dart_tool/package_config.json',
      'root': 'lib/core/nested',
      'sdk_version': '3.13.5',
    });
  });
}
