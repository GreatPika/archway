import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/policy_definition.dart';
import 'package:test/test.dart';

void main() {
  final document = jsonDecode(
    File('contracts/entrypoints/language-acceptance.json').readAsStringSync(),
  ) as Map;
  test('language acceptance inventory declares only Dart source examples', () {
    final cases = document['cases'] as List;
    expect(document['count'], cases.length);
    expect(cases.map((c) => c['id']).toSet(), hasLength(cases.length));
    for (final example in cases) {
      expect(example['language'], 'dart', reason: example['id']);
      expect(
        (example['sources'] as Map).keys.every(
          (path) => (path as String).endsWith('.dart'),
        ),
        true,
        reason: example['id'],
      );
    }
  });
  for (final id in ['dart-public-without-allows', 'dart-private-sameowner']) {
    test(id, () async {
      final example =
          (document['cases'] as List).singleWhere((c) => c['id'] == id) as Map;
      expect(example['language'], 'dart');
      final setup = example['setup'] as Map;
      final public = setup['public'] as Map;
      if (id == 'dart-public-without-allows') {
        expect(public['C'], contains('c/api.dart'));
        expect(setup['allows']['A'], isNot(contains('C')));
      } else {
        expect(public['B'], isNot(contains('b/private.dart')));
      }
      final root = await Directory.systemTemp.createTemp(
        'archway-dart-example-',
      );
      addTearDown(() => root.delete(recursive: true));
      for (final entry in (example['sources'] as Map).entries) {
        final file = File('${root.path}/lib/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value as String);
      }
      await File('${root.path}/pubspec.yaml').writeAsString(
        'name: acceptance_fixture\nenvironment:\n  sdk: ">=3.13.3 <4.0.0"\n',
      );
      final prep = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root.path);
      expect(prep.exitCode, 0, reason: '${prep.stdout}\n${prep.stderr}');
      final owners = setup['owners'] as Map;
      final policy = {
        'version': 1,
        'projects': [
          {
            'id': 'app',
            'adapter': 'dart',
            'package_roots': ['./'],
          },
        ],
        'scope': ['lib/'],
        'exclude': [],
        'nodes': [
          for (final entry in owners.entries)
            {
              'id': entry.value,
              'responsibility': 'Example ${entry.value}',
              'owns': ['lib/${entry.key}'],
              'allows': setup['allows'][entry.value],
              'public': [for (final path in public[entry.value]) 'lib/$path'],
            },
        ],
      };
      await File('${root.path}/architecture.yaml')
          .writeAsString(jsonEncode(policy));
      final result = await Inspection().check(RepositorySelection(root.path));
      expect(
        result.payload['analysis_complete'],
        true,
        reason: jsonEncode(result.payload),
      );
      expect(result.payload['unknowns'], isEmpty);
      expect(result.payload['tool_errors'], isEmpty);
      final violations = result.payload['violations'] as List;
      if (id == 'dart-public-without-allows') {
        expect(result.exitCode, 1);
        expect(violations.map((v) => v['code']), ['DEPENDENCY_NOT_ALLOWED']);
      } else {
        expect(result.exitCode, 0);
        expect(violations, isEmpty);
      }
      final edges = (result.payload['facts'] as Map)['edges'] as List;
      expect(edges, hasLength(1));
      expect(edges.single['resolution']['kind'], 'local');
      expect(
        edges.single['resolution']['path'],
        id == 'dart-public-without-allows'
            ? 'lib/c/api.dart'
            : 'lib/b/private.dart',
      );
    });
  }
}
