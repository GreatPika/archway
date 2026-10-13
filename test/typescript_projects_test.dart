import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prepared references target declarations, never their public source',
    () async {
      final root = await prepared();
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      expect(report.payload['observed'], {
        'files': 5,
        'analyzed_files': 5,
        'edges': 3,
      });
      final edges = (report.payload['facts'] as Map)['edges'] as List;
      final appEdge = edges.singleWhere((e) => e['source'] == 'app/main.ts');
      expect(appEdge['resolution']['path'], 'lib/dist/index.d.ts');
      expect(
        appEdge['resolution']['canonical_file_uri'],
        File('${root.path}/lib/dist/index.d.ts').uri.toString(),
      );
      expect(
        (report.payload['violations'] as List).single['code'],
        'TARGET_NOT_PUBLIC',
      );
      final rows = (report.payload['coverage'] as Map)['files'] as List;
      expect(rows.map((r) => [r['path'], r['project_id']]), [
        ['app/main.ts', 'app'],
        ['lib/dist/index.d.ts', 'app'],
        ['lib/dist/private.d.ts', 'app'],
        ['lib/src/index.ts', 'lib'],
        ['lib/src/private.ts', 'lib'],
      ]);
      final inputs =
          (report.payload['input_identity'] as Map)['inputs'] as List;
      for (final name in [
        'base.json',
        'lib/tsconfig.json',
        'lib/dist/index.d.ts',
      ]) {
        expect(
          inputs.any((i) => i['location']['path'] == name && i['hash'] != null),
          true,
          reason: name,
        );
      }
      expect(
        await File('${root.path}/lib/tsconfig.tsbuildinfo').exists(),
        false,
      );
      expect(await File('${root.path}/lib/dist/index.js').exists(), false);
    },
  );
  test(
    'missing prepared output is incomplete without building or source fallback',
    () async {
      final root = await prepared();
      await File('${root.path}/lib/dist/index.d.ts').delete();
      final out = StringBuffer(), err = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'check',
      ], CliStreams(out, err));
      expect(exit, 2);
      expect(err.toString(), '');
      expect(out.toString().split('\n'), hasLength(2));
      final envelope = jsonDecode(out.toString()) as Map;
      expect(envelope['status'], 'incomplete');
      expect(envelope['exit_code'], 2);
      final payload = envelope['payload'] as Map;
      expect(payload['analysis_complete'], false);
      final edges = (payload['facts'] as Map)['edges'] as List;
      final appEdge = edges.singleWhere((e) => e['source'] == 'app/main.ts');
      expect(appEdge['resolution'], {'kind': 'unresolved'});
      expect(
        (payload['unknowns'] as List).any(
          (u) => u['code'] == 'UNRESOLVED_IMPORT' && u['source_range'] != null,
        ),
        true,
      );
      expect(
        edges.any(
          (e) =>
              e['source'] == 'lib/src/index.ts' &&
              e['resolution']['path'] == 'lib/src/private.ts',
        ),
        true,
      );
      expect(await File('${root.path}/lib/dist/index.d.ts').exists(), false);
      expect(
        await File('${root.path}/lib/tsconfig.tsbuildinfo').exists(),
        false,
      );
    },
  );

  test('shared prepared declarations preserve both sorted membership candidates', () async {
    final root = await prepared();
    await File('${root.path}/other.json').writeAsString(
      '{"extends":"./base.json","files":["lib/dist/index.d.ts"]}',
    );
    final policy = File('${root.path}/architecture.yaml');
    await policy.writeAsString(
      (await policy.readAsString()).replaceFirst(
        'projects:',
        'projects:\n  - {id: other, adapter: typescript, tsconfig: other.json}',
      ),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final rows = (report.payload['coverage'] as Map)['files'] as List;
    for (final row in rows.where((r) => r['path'].startsWith('lib/dist/'))) {
      expect(
        row['assignment'],
        'ambiguous',
        reason: jsonEncode(report.payload['tool_errors']),
      );
      expect(row['project_id'], null);
      expect(row['context_id'], null);
      expect(row['candidates'], [
        {'project_id': 'app', 'context_id': 'typescript:app'},
        {'project_id': 'other', 'context_id': 'typescript:other'},
      ]);
      expect(row['unresolved_project_ids'], isEmpty);
    }
    expect(rows.last['project_id'], 'lib');
  });

  test('failed project discovery preserves known candidates and unresolved projects', () async {
    final root = await prepared();
    final policy = File('${root.path}/architecture.yaml');
    await policy.writeAsString(
      (await policy.readAsString()).replaceFirst(
        'projects:',
        'projects:\n  - {id: broken, adapter: typescript, tsconfig: missing.json}',
      ),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final rows = (report.payload['coverage'] as Map)['files'] as List;
    for (final row in rows) {
      expect(row['assignment'], 'failed');
      expect(row['discovery_complete'], false);
      expect(row['unresolved_project_ids'], ['broken']);
      expect(row['project_id'], null);
      expect(row['context_id'], null);
    }
    expect(rows.first['candidates'], [
      {'project_id': 'app', 'context_id': 'typescript:app'},
    ]);
    expect(rows.last['candidates'], [
      {'project_id': 'lib', 'context_id': 'typescript:lib'},
    ]);
    expect((report.payload['facts'] as Map)['edges'], hasLength(3));
    expect(
      (report.payload['tool_errors'] as List).any(
        (e) => e['project_id'] == 'broken',
      ),
      true,
    );
  });

  test(
    'require preserves an actual Program prepared declaration redirect',
    () async {
      final root = await prepared();
      await File('${root.path}/app/main.ts').writeAsString(
        "import '../lib/src/index';\nrequire('../lib/src/index');\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['analysis_complete'], true);
      final edges = ((report.payload['facts'] as Map)['edges'] as List)
          .where((e) => e['source'] == 'app/main.ts')
          .toList();
      expect(edges.map((e) => e['kind']), ['import', 'require']);
      expect(edges.map((e) => e['resolution']['path']), [
        'lib/dist/index.d.ts',
        'lib/dist/index.d.ts',
      ]);
    },
  );

  test(
    'solution references do not silently declare leaf inspection projects',
    () async {
      final root = await prepared();
      await File('${root.path}/tsconfig.json')
          .writeAsString('{"files":[],"references":[{"path":"./lib"}]}');
      final policy = File('${root.path}/architecture.yaml');
      await policy.writeAsString(
        (await policy.readAsString()).replaceFirst(
          '  - {id: lib, adapter: typescript, tsconfig: lib/tsconfig.json}\n',
          '',
        ),
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final rows = (report.payload['coverage'] as Map)['files'] as List;
      expect(rows, hasLength(5));
      expect(rows.map((r) => r['assignment']), everyElement('missing'));
      expect(rows.map((r) => r['candidates']), everyElement(isEmpty));
      expect((report.payload['coverage'] as Map)['projects'], hasLength(1));
    },
  );

  test(
    'an unreadable referenced configuration prevents complete discovery',
    () async {
      final root = await prepared();
      await File('${root.path}/tsconfig.json').writeAsString(
        '{"extends":"./base.json","include":["app/**/*.ts"],"references":[{"path":"./missing"}]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['tool_errors'] as List).any(
          (e) =>
              e['project_id'] == 'app' &&
              e['code'] == 'TYPESCRIPT_CONFIG_ERROR',
        ),
        true,
      );
      final rows = (report.payload['coverage'] as Map)['files'] as List;
      expect(rows.first['discovery_complete'], false);
      expect(rows.first['unresolved_project_ids'], ['app']);
    },
  );

  test(
    'prepared mts and cts projects keep their matching declaration extensions',
    () async {
      for (final extension in ['mts', 'cts']) {
        final root = await prepared();
        final js = extension == 'mts' ? 'mjs' : 'cjs';
        await File('${root.path}/base.json').writeAsString(
          '{"compilerOptions":{"target":"ES2022","module":"NodeNext","moduleResolution":"NodeNext"}}',
        );
        for (final config in ['tsconfig.json', 'lib/tsconfig.json']) {
          final file = File('${root.path}/$config');
          await file.writeAsString(
            (await file.readAsString()).replaceAll('**/*.ts', '**/*'),
          );
        }
        for (final source in [
          'app/main.ts',
          'lib/src/index.ts',
          'lib/src/private.ts',
          'lib/dist/index.d.ts',
          'lib/dist/private.d.ts',
        ]) {
          final file = File('${root.path}/$source');
          await file.writeAsString(
            (await file.readAsString())
                .replaceAll("'../lib/src/index'", "'../lib/src/index.$js'")
                .replaceAll("'./private'", "'./private.$js'"),
          );
          await file.rename(
            '${root.path}/${source.substring(0, source.length - 2)}$extension',
          );
        }
        final policy = File('${root.path}/architecture.yaml');
        await policy.writeAsString(
          (await policy.readAsString()).replaceFirst(
            'lib/src/index.ts',
            'lib/src/index.$extension',
          ),
        );
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'negative', reason: extension);
        expect(report.payload['analysis_complete'], true);
        final edge = ((report.payload['facts'] as Map)['edges'] as List)
            .singleWhere((e) => e['source'] == 'app/main.$extension');
        expect(edge['resolution']['path'], 'lib/dist/index.d.$extension');
        expect(
          (report.payload['violations'] as List).single['code'],
          'TARGET_NOT_PUBLIC',
        );
      }
    },
  );

  test(
    'prepared CLI check emits complete successful and negative JSON envelopes',
    () async {
      final root = await prepared();
      for (final allowed in [false, true]) {
        if (allowed) {
          final policy = File('${root.path}/architecture.yaml');
          await policy.writeAsString(
            (await policy.readAsString()).replaceFirst(
              'public: [lib/src/index.ts]',
              'public: [lib/dist/index.d.ts]',
            ),
          );
        }
        final out = StringBuffer(), err = StringBuffer();
        final exit = await CLI().run([
          '--root',
          root.path,
          'check',
        ], CliStreams(out, err));
        expect(exit, allowed ? 0 : 1);
        expect(err.toString(), '');
        expect(out.toString().split('\n'), hasLength(2));
        final envelope = jsonDecode(out.toString()) as Map;
        expect(envelope.keys.toSet(), {
          'command',
          'schema_version',
          'tool_versions',
          'resolved_root',
          'policy_path',
          'policy_hash',
          'status',
          'exit_code',
          'diagnostics',
          'payload',
        });
        expect(envelope['command'], 'check');
        expect(envelope['schema_version'], 1);
        expect(envelope['status'], allowed ? 'ok' : 'negative');
        expect(envelope['exit_code'], allowed ? 0 : 1);
        expect(envelope['diagnostics'], isEmpty);
        expect(envelope['tool_versions']['node'], '24.21.0');
        expect(envelope['tool_versions']['typescript'], '5.9.3');
        final payload = envelope['payload'] as Map;
        expect(payload.keys.toSet(), {
          'policy_valid',
          'analysis_complete',
          'violations',
          'unknowns',
          'warnings',
          'tool_errors',
          'observed',
          'coverage',
          'facts',
          'input_identity',
          'scope',
          'exclude',
          'projects',
          'nodes',
        });
        expect(payload['analysis_complete'], true);
        expect(payload['policy_valid'], true);
        expect(payload['input_identity']['rechecked'], true);
        expect(payload['observed'], {
          'files': 5,
          'analyzed_files': 5,
          'edges': 3,
        });
        expect(payload['violations'], hasLength(allowed ? 0 : 1));
        expect(payload['unknowns'], isEmpty);
        expect(payload['tool_errors'], isEmpty);
      }
    },
  );
}

Future<Directory> prepared() async {
  final root = await Directory.systemTemp.createTemp('archway-ts-projects-');
  addTearDown(() => root.delete(recursive: true));
  final files = {
    'package.json': '{"type":"commonjs"}',
    'base.json': '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
    'tsconfig.json': '{"extends":"./base.json","include":["app/**/*.ts"],"references":[{"path":"./lib"}]}',
    'app/main.ts': "import {value} from '../lib/src/index';\n",
    'lib/tsconfig.json': '{"extends":"../base.json","compilerOptions":{"composite":true,"declaration":true,"declarationMap":true,"rootDir":"src","outDir":"dist"},"include":["src/**/*.ts"]}',
    'lib/src/index.ts': "export {value} from './private';\n",
    'lib/src/private.ts': 'export const value = 1;\n',
    'lib/dist/index.d.ts': "export {value} from './private';\n//# sourceMappingURL=index.d.ts.map\n",
    'lib/dist/private.d.ts': 'export declare const value: number;\n',
    'architecture.yaml': '''
version: 1
projects:
  - {id: app, adapter: typescript, tsconfig: tsconfig.json}
  - {id: lib, adapter: typescript, tsconfig: lib/tsconfig.json}
scope: [app/, lib/src/, lib/dist/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [app/], allows: [lib], public: []}
  - {id: lib, responsibility: Lib, owns: [lib/], allows: [], public: [lib/src/index.ts]}
''',
  };
  for (final entry in files.entries) {
    final file = File('${root.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  return root;
}
