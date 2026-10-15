import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'typescript_fixture.dart' show fixture;

void main() {
  test(
    'nested ambient augmentation is a positioned unsupported reference',
    () async {
      final root = await fixture(
        main: "declare module 'ambient' { module 'target' { interface Added {} } }\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final unknown = (report.payload['unknowns'] as List).single;
      expect(unknown['code'], 'UNSUPPORTED_MODULE_REFERENCE');
      expect(unknown['source_range']['path'], 'src/app/main.ts');
      expect(unknown['source_range']['start'], {'line': 1, 'column': 28});
      expect((report.payload['facts'] as Map)['edges'], isEmpty);
    },
  );
  test(
    'unrepresentable references keep positioned unknowns and verified imports',
    () async {
      for (final reference in [
        "import('../core/' + name);",
        r"import(`../core/${name}`);",
        "require(name);",
        "/// <reference path=\"../core/private.ts\" />",
        "/// <reference types=\"missing-types\" />",
        "/// <reference lib=\"es2020\" />",
        "declare module '../core/private' { interface Added {} }",
      ]) {
        final root = await fixture(
          main: "$reference\nimport {value} from '../core/private';\n",
        );
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete', reason: reference);
        final edges = (report.payload['facts'] as Map)['edges'] as List;
        expect(edges, hasLength(1), reason: reference);
        expect(edges.single['resolution']['path'], 'src/core/private.ts');
        final unknowns = (report.payload['unknowns'] as List)
            .where((u) => u['code'] == 'UNSUPPORTED_MODULE_REFERENCE')
            .toList();
        expect(unknowns, hasLength(1), reason: reference);
        expect(unknowns.single['source_range']['start']['line'], 1);
        expect(unknowns.single['source_range']['path'], 'src/app/main.ts');
        expect(
          (report.payload['violations'] as List).single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
      }
    },
  );

  test(
    'an invalid resolution mode cannot certify otherwise resolved references',
    () async {
      final root = await fixture(
        main: '''import type {Value} from '../core/private.js' with {"resolution-mode":"bogus"};
import {value} from '../core/private.js';
''',
        config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*.ts"]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['unknowns'] as List).any(
          (u) => u['source_range']?['start']['line'] == 1,
        ),
        true,
      );
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      expect(edges, hasLength(1));
      expect(
        edges.any(
          (e) =>
              e['source_range']['start']['line'] == 2 &&
              e['resolution']['path'] == 'src/core/private.ts',
        ),
        true,
      );
    },
  );

  test(
    'global ambient declarations and SDK symbols do not invent dependencies',
    () async {
      final root = await fixture(
        main:
            "declare module 'virtual' { export interface Value {} }\n"
            "const value: Promise<number> = Promise.resolve(1);\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'ok');
      expect(report.payload['analysis_complete'], true);
      expect((report.payload['facts'] as Map)['edges'], isEmpty);
      expect(report.payload['unknowns'], isEmpty);
    },
  );

  test(
    'resolution-mode on a value import cannot be silently ignored',
    () async {
      final root = await fixture(
        main: "import {value} from '../core/private.js' with {\"resolution-mode\":\"require\"};\n",
        config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*.ts"]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['unknowns'] as List).singleWhere(
          (u) => u['code'] == 'UNSUPPORTED_MODULE_REFERENCE',
        )['source_range']['start']['line'],
        1,
      );
    },
  );
}
