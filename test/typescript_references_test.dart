import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'typescript_fixture.dart' show fixture;

void main() {
  test(
    'a re-export keeps its direct barrel target and occurrence range',
    () async {
      final root = await fixture(
        main: "export {value} from '../core/private';\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
      expect(edge['kind'], 'export');
      expect(edge['specifier'], '../core/private');
      expect(edge['type_only'], false);
      expect(edge['source_range'], {
        'path': 'src/app/main.ts',
        'start': {'line': 1, 'column': 1},
        'end': {'line': 1, 'column': 39},
      });
      expect(edge['resolution']['path'], 'src/core/private.ts');
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );
  test('all type-only re-export bindings retain a type-only edge', () async {
    final root = await fixture(
      main: "export {type Value} from '../core/private';\n",
    );
    await File('${root.path}/src/core/private.ts')
        .writeAsString('export type Value = string;\n');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'negative');
    final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
    expect(edge['kind'], 'export');
    expect(edge['type_only'], true);
  });

  test(
    'import-equals uses the import fact kind and retains type-only',
    () async {
      final root = await fixture(
        main: "import type value = require('../core/private');\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
      expect(edge['kind'], 'import');
      expect(edge['type_only'], true);
      expect(edge['resolution']['path'], 'src/core/private.ts');
    },
  );

  test(
    'import-type and typeof import report separate type dependencies',
    () async {
      final root = await fixture(
        main:
            "type A = import('../core/private').Value;\n"
            "type B = typeof import('../core/private');\n",
      );
      await File('${root.path}/src/core/private.ts')
          .writeAsString('export type Value = string;\n');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      expect(edges.map((e) => e['kind']), ['import_type', 'import_type']);
      expect(edges.map((e) => e['type_only']), [true, true]);
      expect(edges.map((e) => e['source_range']['start']['line']), [1, 2]);
      expect(edges.map((e) => e['resolution']['path']), [
        'src/core/private.ts',
        'src/core/private.ts',
      ]);
    },
  );

  test('literal dynamic import retains its expression span', () async {
    final root = await fixture(
      main: "const lazy = import('../core/private');\n",
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'negative');
    expect(report.payload['analysis_complete'], true);
    final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
    expect(edge['kind'], 'dynamic_import');
    expect(edge['type_only'], false);
    expect(edge['source_range'], {
      'path': 'src/app/main.ts',
      'start': {'line': 1, 'column': 14},
      'end': {'line': 1, 'column': 39},
    });
    expect(edge['resolution']['path'], 'src/core/private.ts');
  });

  test('a no-substitution template is a literal dynamic import', () async {
    final root = await fixture(main: "import(`../core/private`);\n");
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'negative');
    expect(report.payload['analysis_complete'], true);
    final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
    expect(edge['specifier'], '../core/private');
    expect(edge['resolution']['path'], 'src/core/private.ts');
  });

  test(
    'literal require resolves an actual Program target as a require edge',
    () async {
      final root = await fixture(
        main: "const value = require('../core/private');\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
      expect(edge['kind'], 'require');
      expect(edge['type_only'], false);
      expect(edge['resolution']['path'], 'src/core/private.ts');
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );

  test('require uses CommonJS mode inside ESM while the same import stays unresolved', () async {
    final root = await fixture(
      main: "import '../core/private';\nrequire('../core/private');\n",
      config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*"]}',
    );
    await File('${root.path}/src/app/main.ts')
        .rename('${root.path}/src/app/main.mts');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.map((e) => e['kind']), ['import', 'require']);
    expect(edges[0]['resolution'], {'kind': 'unresolved'});
    expect(edges[1]['resolution']['path'], 'src/core/private.ts');
    expect(
      (report.payload['violations'] as List).single['code'],
      'DEPENDENCY_NOT_ALLOWED',
    );
    expect(
      (report.payload['unknowns'] as List)
          .single['source_range']['start']['line'],
      1,
    );
  });

  test(
    'require-only targets absent from Program stay unknown and unassigned',
    () async {
      final root = await fixture(
        main: "require('../core/private');\n",
        config: '{"compilerOptions":{"module":"CommonJS"},"files":["src/app/main.ts"]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
      expect(edge['kind'], 'require');
      expect(edge['resolution'], {'kind': 'unresolved'});
      final rows = (report.payload['coverage'] as Map)['files'] as List;
      expect(rows.last['path'], 'src/core/private.ts');
      expect(rows.last['assignment'], 'missing');
      expect(rows.last['candidates'], isEmpty);
      final unknown = (report.payload['unknowns'] as List).singleWhere(
        (u) => u['code'] == 'UNRESOLVED_IMPORT',
      );
      expect(unknown['source_range']['start'], {'line': 1, 'column': 1});
    },
  );

  test(
    'type references honor each occurrence resolution-mode override',
    () async {
      final root = await fixture(
        main: '''import type {Value as A} from '../core/private' with {"resolution-mode":"import"};
import type {Value as B} from '../core/private' with {"resolution-mode":"require"};
type C = import('../core/private', {with: {"resolution-mode":"import"}}).Value;
type D = import('../core/private', {with: {"resolution-mode":"require"}}).Value;
''',
        config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*"]}',
      );
      await File('${root.path}/src/app/main.ts')
          .rename('${root.path}/src/app/main.mts');
      await File('${root.path}/src/core/private.ts')
          .writeAsString('export type Value = string;');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      expect(edges.map((e) => e['kind']), [
        'import',
        'import',
        'import_type',
        'import_type',
      ]);
      expect(edges.map((e) => e['type_only']), everyElement(true));
      expect(edges.map((e) => e['resolution']['kind']), [
        'unresolved',
        'local',
        'unresolved',
        'local',
      ]);
      expect(edges.map((e) => e['source_range']['start']['line']), [
        1,
        2,
        3,
        4,
      ]);
      expect(report.payload['violations'], hasLength(2));
    },
  );

  test('a CommonJS source resolves static import and dynamic import in distinct modes', () async {
    final root = await fixture(
      main: "import '../core/private';\nimport('../core/private');\n",
      config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*"]}',
    );
    await File('${root.path}/src/app/main.ts')
        .rename('${root.path}/src/app/main.cts');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.map((e) => e['kind']), ['import', 'dynamic_import']);
    expect(edges[0]['resolution']['path'], 'src/core/private.ts');
    expect(edges[1]['resolution'], {'kind': 'unresolved'});
    expect(report.payload['violations'], hasLength(1));
  });
}
