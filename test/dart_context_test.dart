import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture;

void main() {
  test('actual nested and package-included option sources define one context descriptor', () async {
    final root = await dartFixture();
    await Directory('${root.path}/rules/lib').create(recursive: true);
    await File('${root.path}/shared.yaml')
        .writeAsString('analyzer:\n  language:\n    strict-inference: true\n');
    await File('${root.path}/rules/lib/base.yaml')
        .writeAsString('include: ../../shared.yaml\n');
    await File('${root.path}/analysis_options.yaml')
        .writeAsString('include: package:rules/base.yaml\n');
    await File('${root.path}/lib/app/analysis_options.yaml')
        .writeAsString('analyzer:\n  language:\n    strict-casts: true\n');
    final configFile = File('${root.path}/.dart_tool/package_config.json');
    final config = jsonDecode(await configFile.readAsString()) as Map;
    (config['packages'] as List).add({
      'name': 'rules',
      'rootUri': '../rules/',
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });
    await configFile.writeAsString(jsonEncode(config));
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(
      report.status,
      'negative',
      reason: jsonEncode(report.payload['tool_errors']),
    );
    final contexts =
        ((report.payload['coverage'] as Map)['projects'] as List)
                .single['contexts']
            as List;
    expect(contexts.single['descriptor'], {
      'excluded_paths': [],
      'included_paths': ['./'],
      'options_paths': [
        'analysis_options.yaml',
        'lib/app/analysis_options.yaml',
        'rules/lib/base.yaml',
        'shared.yaml',
      ],
      'package_config_path': '.dart_tool/package_config.json',
      'root': './',
      'sdk_version': '3.13.3',
    });
    expect(
      contexts.single['context_id'],
      'dart:app:1e80fd25b9385084e24b63b389f074f0b45534f6d945ff496618e0f2db15410f',
    );
  });
  test(
    'analyzer exclusions retain the independent corpus and known incoming edge',
    () async {
      final root = await dartFixture();
      await File('${root.path}/analysis_options.yaml')
          .writeAsString('analyzer:\n  exclude: [lib/core/private.dart]\n');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final rows = (report.payload['coverage'] as Map)['files'] as List;
      expect(rows.map((r) => r['path']), [
        'lib/app/main.dart',
        'lib/core/private.dart',
      ]);
      expect(rows.last['assignment'], 'missing');
      expect(rows.last['discovery_complete'], true);
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );
}
