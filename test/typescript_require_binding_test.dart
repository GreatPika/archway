import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'typescript_fixture.dart' show fixture;

void main() {
  test(
    'a locally bound require never fabricates a resolved dependency',
    () async {
      final root = await fixture(
        main: "const require = (name: string) => 42;\nrequire('../core/private');\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect((report.payload['facts'] as Map)['edges'], isEmpty);
      expect(report.payload['violations'], isEmpty);
      final unknown = (report.payload['unknowns'] as List).singleWhere(
        (u) => u['code'] == 'UNSUPPORTED_MODULE_REFERENCE',
      );
      expect(unknown['source_range']['path'], 'src/app/main.ts');
      expect(unknown['source_range']['start'], {'line': 2, 'column': 1});
    },
  );
  test(
    'parameters nested bindings and ambient require declarations stay unproved',
    () async {
      for (final main in [
        "function call() { const require = (name: string) => 42; require('../core/private'); }\n",
        "declare function require(name: string): unknown;\nrequire('../core/private');\n",
      ]) {
        final root = await fixture(main: main);
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete', reason: main);
        expect((report.payload['facts'] as Map)['edges'], isEmpty);
        expect(report.payload['violations'], isEmpty);
        final unknown = (report.payload['unknowns'] as List).singleWhere(
          (u) => u['code'] == 'UNSUPPORTED_MODULE_REFERENCE',
        );
        expect(unknown['source_range']['path'], 'src/app/main.ts');
        expect(unknown['source_range']['start']['column'], greaterThan(0));
      }
    },
  );

  test(
    'an independent unbound require retains its verified target and violation',
    () async {
      final root = await fixture(
        main:
            "function call(require: (name: string) => number) { require('../core/private'); }\n"
            "require('../core/private');\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
      expect(edge['kind'], 'require');
      expect(edge['source_range']['start'], {'line': 2, 'column': 1});
      expect(edge['resolution']['path'], 'src/core/private.ts');
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
      final unknown = (report.payload['unknowns'] as List).singleWhere(
        (u) => u['code'] == 'UNSUPPORTED_MODULE_REFERENCE',
      );
      expect(unknown['source_range']['start']['line'], 1);
    },
  );
}
