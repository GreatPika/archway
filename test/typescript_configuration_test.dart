import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'typescript_fixture.dart' show fixture;

void main() {
  test(
    'local paths mappings use inherited configuration-relative targets',
    () async {
      final root = await fixture(
        main: "import {value} from '@core/private';\n",
        config: '{"extends":"./config/base.json"}',
      );
      await Directory('${root.path}/config').create();
      await File('${root.path}/config/base.json').writeAsString('''{
      // Relative paths belong to this base, not the selected tsconfig.
      "compilerOptions": {"module":"CommonJS","target":"ES2020",
        "paths": {"@core/*": ["../src/core/*"]}},
      "include": ["../src/**/*.ts"],
    }''');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      final edge = ((report.payload['facts'] as Map)['edges'] as List).single;
      expect(edge['specifier'], '@core/private');
      expect(edge['resolution']['path'], 'src/core/private.ts');
      expect((report.payload['coverage'] as Map)['projects'], hasLength(1));
    },
  );
  test('standard module-resolution and target representatives stay supported', () async {
    for (final options in [
      '"module":"Node16","moduleResolution":"Node16","target":"ES2020"',
      '"module":"NodeNext","moduleResolution":"NodeNext","target":"ES2022"',
      '"module":"Preserve","moduleResolution":"Bundler","target":"ESNext"',
      '"module":"ESNext","moduleResolution":"Bundler","target":"ES2020"',
      '"module":"CommonJS","moduleResolution":"Node10","target":"ES2022"',
      '"module":"ES2015","moduleResolution":"Classic","target":"ES5"',
    ]) {
      final root = await fixture(
        main: "import {value} from '../core/private.js';\nconst wrong: string = 42;\n",
        config: '{"compilerOptions":{$options},"include":["src/**/*.ts"]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(
        report.status,
        'negative',
        reason:
            '$options ${report.payload['unknowns']} ${report.payload['tool_errors']} changed=${(report.payload['input_identity'] as Map)['changed_inputs']}',
      );
      expect(report.payload['analysis_complete'], true, reason: options);
      expect(report.payload['tool_errors'], isEmpty);
      expect(
        ((report.payload['facts'] as Map)['edges'] as List)
            .single['resolution']['path'],
        'src/core/private.ts',
      );
    }
  });

  test(
    'baseUrl resolves local code without installing or classifying packages',
    () async {
      final root = await fixture(
        main: "import {value} from 'core/private';\n",
        config: '{"compilerOptions":{"module":"CommonJS","baseUrl":"./src"},"include":["src/**/*.ts"]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      expect(
        ((report.payload['facts'] as Map)['edges'] as List)
            .single['resolution']['path'],
        'src/core/private.ts',
      );
    },
  );

  test('tsx supports the four standard JSX modes with local runtime inputs', () async {
    for (final jsx in ['preserve', 'react', 'react-jsx', 'react-jsxdev']) {
      final root = await fixture(
        main: "import {value} from '../core/private';\nconst view = <div>{value}</div>;\n",
        config:
            '{"compilerOptions":{"target":"ES2022","module":"CommonJS","jsx":"$jsx","jsxImportSource":"../core"},"include":["src/**/*"]}',
      );
      // Classic JSX modes do not accept jsxImportSource.
      if (jsx == 'preserve' || jsx == 'react') {
        final config = File('${root.path}/tsconfig.json');
        await config.writeAsString(
          (await config.readAsString()).replaceFirst(
            ',"jsxImportSource":"../core"',
            '',
          ),
        );
      }
      await File('${root.path}/src/app/main.ts')
          .rename('${root.path}/src/app/main.tsx');
      for (final runtime in ['jsx-runtime', 'jsx-dev-runtime']) {
        await File('${root.path}/src/core/$runtime.ts').writeAsString(
          'export function jsx() {} export function jsxs() {} export function jsxDEV() {}',
        );
      }
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative', reason: jsx);
      expect(report.payload['analysis_complete'], true, reason: jsx);
      expect((report.payload['facts'] as Map)['edges'], hasLength(1));
    }
  });

  test('invalid and unsupported inherited configuration keeps discovery unresolved', () async {
    for (final config in [
      '{"extends":"./missing.json","include":["src/**/*.ts"]}',
      '{"compilerOptions":{"module":"CommonJS","moduleResolution":"NodeNext"},"include":["src/**/*.ts"]}',
      '{"compilerOptions":{"noResolve":true},"include":["src/**/*.ts"]}',
      '{"compilerOptions":{"plugins":[{"name":"./never-run.cjs"}]},"include":["src/**/*.ts"]}',
    ]) {
      final root = await fixture(config: config);
      await File('${root.path}/never-run.cjs')
          .writeAsString('throw Error("must never load");');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete', reason: config);
      expect(report.payload['tool_errors'], isNotEmpty);
      final rows = (report.payload['coverage'] as Map)['files'] as List;
      expect(rows.map((r) => r['assignment']), everyElement('failed'));
      expect(
        rows.map((r) => r['unresolved_project_ids']),
        everyElement(['web']),
      );
    }
  });
}
