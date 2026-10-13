import 'dart:io';
import 'dart:convert';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/installation_layout.dart';
import 'package:path/path.dart' as p;
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

void main() {
  test('invalid policy stops inspection before compiler discovery', () async {
    final root = await Directory.systemTemp.createTemp('archway-inspection-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/architecture.yaml').writeAsString('version: 9');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'invalid_policy');
    expect(report.payload['policy_valid'], false);
    expect(report.payload['analysis_complete'], false);
    expect(report.payload['observed'], {
      'files': 0,
      'analyzed_files': 0,
      'edges': 0,
    });
    expect(report.payload['coverage'], {'files': [], 'projects': []});
    expect(report.toolVersions.values.every((v) => v == null), true);
  });
  test('a real TypeScript local import retains its span and denied boundary', () async {
    final root = await Directory.systemTemp.createTemp('archway-inspection-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/src/app').create(recursive: true);
    await Directory('${root.path}/src/core').create(recursive: true);
    await File('${root.path}/src/app/main.ts').writeAsString(
      "import {value} from '../core/private';\nconsole.log(value);\n",
    );
    await File('${root.path}/src/core/private.ts')
        .writeAsString('export const value = 1;\n');
    await File('${root.path}/tsconfig.json').writeAsString(
      '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}',
    );
    await File('${root.path}/architecture.yaml')
        .writeAsString(typescriptPolicy);
    final report = await Inspection().check(RepositorySelection(root.path));
    if (Platform.isWindows && report.status != 'negative') {
      try {
        final assets = p.normalize(
          (await InstallationLayout.resolve()).typescriptAssets,
        );
        final paths = <String>{
          ...p
              .split(assets)
              .asMap()
              .keys
              .map((i) => p.joinAll(p.split(assets).take(i + 1))),
          p.join(assets, 'vendor'),
          p.join(assets, 'vendor/typescript'),
          p.join(assets, 'vendor/yaml'),
        };
        for (final path in paths) {
          final type = FileSystemEntity.typeSync(path, followLinks: false);
          String? resolved;
          String? error;
          try {
            resolved = Directory(path).resolveSymbolicLinksSync();
          } catch (failure) {
            error = failure.toString();
          }
          print(
            '[DEBUG-windows-adapter-path] ${jsonEncode({'requested': path, 'normalized': p.normalize(path), 'type': type.toString(), 'resolved': resolved, 'error': error})}',
          );
        }
      } catch (failure) {
        print('[DEBUG-windows-adapter-path] diagnostics unavailable: $failure');
      }
    }
    expect(report.status, 'negative', reason: jsonEncode(report.payload));
    expect(report.payload['analysis_complete'], true);
    expect(report.payload['observed'], {
      'files': 2,
      'analyzed_files': 2,
      'edges': 1,
    });
    final edge =
        ((report.payload['facts'] as Map)['edges'] as List).single as Map;
    expect(edge['source_range'], {
      'path': 'src/app/main.ts',
      'start': {'line': 1, 'column': 1},
      'end': {'line': 1, 'column': 39},
    });
    expect(edge['resolution'], {
      'kind': 'local',
      'path': 'src/core/private.ts',
      'canonical_file_uri': File('${root.path}/src/core/private.ts').uri
          .toString(),
      'via_path': null,
    });
    expect(
      (report.payload['violations'] as List).single,
      containsPair('code', 'DEPENDENCY_NOT_ALLOWED'),
    );
    expect((report.payload['input_identity'] as Map)['rechecked'], true);
    expect(report.toolVersions['typescript'], '5.9.3');
  });

  test(
    'CLI check emits its complete report and status on stdout only',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-check-cli-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final stdout = StringBuffer(), stderr = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'check',
      ], CliStreams(stdout, stderr));
      expect(exit, 0);
      expect(stderr.toString(), '');
      expect(stdout.toString().split('\n'), hasLength(2));
      final output = jsonDecode(stdout.toString()) as Map;
      expect(output['command'], 'check');
      expect(output['status'], 'ok');
      expect(output['exit_code'], 0);
      expect(output['payload'], containsPair('analysis_complete', true));
      expect(
        (output['payload']['input_identity']['inputs'] as List).single['kind'],
        'policy',
      );
    },
  );

  test(
    'unsupported effective configuration cannot certify context assignment',
    () async {
      final root = await fixture(
        config:
            '{"compilerOptions":{"allowJs":true},"include":["src/**/*.ts"]}',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      final files = (report.payload['coverage'] as Map)['files'] as List;
      expect(
        files.every(
          (f) =>
              f['discovery_complete'] == false && f['assignment'] == 'failed',
        ),
        true,
      );
      expect(files.first['unresolved_project_ids'], ['web']);
      expect(files.first['candidates'], [
        {'project_id': 'web', 'context_id': 'typescript:web'},
      ]);
    },
  );

  test(
    'a known violation survives an unresolved import in an incomplete report',
    () async {
      final root = await fixture(
        main: "import {value} from '../core/private';\nimport './missing';\n",
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 2,
      });
      expect(
        (report.payload['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
      expect(
        (report.payload['unknowns'] as List).map((d) => d['code']),
        contains('UNRESOLVED_IMPORT'),
      );
      final inputs =
          (report.payload['input_identity'] as Map)['inputs'] as List;
      expect(
        inputs.any(
          (i) =>
              i['presence'] == 'absent' &&
              i['location']['path'] == 'src/app/missing.ts',
        ),
        true,
      );
      expect(inputs.any((i) => i['kind'] == 'inventory'), true);
    },
  );

  test(
    'policy-excluded directory aliases do not create corpus failures',
    () async {
      final root = await fixture(
        policy: typescriptPolicy.replaceFirst(
          'exclude: []',
          'exclude: [src/ignored/]',
        ),
      );
      await Link('${root.path}/src/ignored').create('${root.path}/src/core');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(report.payload['unknowns'], isEmpty);
      expect(report.payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      });
    },
  );

  test('compiler tracing cannot corrupt the helper JSON channel', () async {
    final root = await fixture(
      config: '{"compilerOptions":{"target":"ES2022","module":"CommonJS","traceResolution":true},"include":["src/**/*.ts"]}',
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'negative');
    expect(report.payload['tool_errors'], isEmpty);
  });

  test('compiler filesystem case-sensitivity probes join the public input identity', () async {
    final root = await fixture();
    // Independent filesystem oracle for TS 5.9.3's ASCII swapCase(__filename),
    // not an assumption that every supported volume is case-sensitive.
    final compiler = await File(
      'assets/typescript/vendor/typescript/lib/typescript.js',
    ).resolveSymbolicLinks();
    final probe = File(
      compiler.replaceAllMapped(RegExp(r'[A-Za-z]'), (match) {
        final char = match[0]!;
        return char == char.toUpperCase()
            ? char.toLowerCase()
            : char.toUpperCase();
      }),
    );
    // TS 5.9.3 typescript.js:8483-8487 returns false immediately on Windows;
    // only Unix hosts actually consult swapCase(__filename).
    final probesCase = !Platform.isWindows;
    final present = probesCase && await probe.exists();
    final expectPresent = !probesCase || present;
    if (present) {
      expect(await probe.resolveSymbolicLinks(), compiler);
    } else if (probesCase) {
      expect(
        await FileSystemEntity.type(probe.path),
        FileSystemEntityType.notFound,
      );
    }
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'negative');
    expect(report.payload['analysis_complete'], isTrue);
    expect(report.payload['tool_errors'], isEmpty);
    final identity = report.payload['input_identity'] as Map;
    expect(identity['rechecked'], isTrue);
    expect(identity['changed_inputs'], isEmpty);
    expect(
      identity['inputs'],
      contains(
        equals({
          'kind': 'resolution',
          'location': {
            'kind': 'external',
            'canonical_file_uri': expectPresent
                ? File(compiler).uri.toString()
                : probe.uri.toString(),
          },
          'presence': expectPresent ? 'present' : 'absent',
          'hash': expectPresent
              ? 'sha256:3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675'
              : null,
        }),
      ),
      reason: jsonEncode(identity),
    );
    if (present) {
      expect(
        identity['aliases'],
        contains(
          equals({
            'observed_file_uri': probe.uri.toString(),
            'canonical_file_uri': File(compiler).uri.toString(),
          }),
        ),
        reason: jsonEncode(identity),
      );
    } else if (!probesCase) {
      expect(
        (identity['inputs'] as List).where(
          (input) =>
              input['location']['canonical_file_uri'] == probe.uri.toString(),
        ),
        isEmpty,
        reason: 'Windows must not invent the skipped case probe',
      );
      expect(
        (identity['aliases'] as List).where(
          (alias) => alias['observed_file_uri'] == probe.uri.toString(),
        ),
        isEmpty,
        reason: 'Windows must not invent a swapped-path alias',
      );
    }
  });
  test(
    'a declared TypeScript project can prove its empty policy corpus',
    () async {
      final root = await fixture(
        policy: typescriptPolicy
            .replaceFirst('scope: [src/]', 'scope: []')
            .replaceFirst('owns: [src/app/]', 'owns: []')
            .replaceFirst('owns: [src/core/]', 'owns: []'),
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'ok');
      expect(report.payload['observed'], {
        'files': 0,
        'analyzed_files': 0,
        'edges': 0,
      });
      expect((report.payload['coverage'] as Map)['projects'], [
        {
          'project_id': 'web',
          'adapter': 'typescript',
          'status': 'complete',
          'files': 0,
          'analyzed_files': 0,
          'contexts': [
            {
              'context_id': 'typescript:web',
              'descriptor': {'tsconfig': 'tsconfig.json'},
            },
          ],
        },
      ]);
    },
  );

  test('the independent corpus keeps compiler-excluded generated declarations and unsupported code', () async {
    final root = await fixture(
      config: '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"files":["src/app/main.ts"],"exclude":["src/generated.ts","src/types.d.ts"]}',
    );
    await File('${root.path}/src/generated.ts')
        .writeAsString('// generated\nexport {};');
    await File('${root.path}/src/types.d.ts')
        .writeAsString('declare const value: string;');
    await File('${root.path}/src/legacy.js').writeAsString('');
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final coverage = (report.payload['coverage'] as Map)['files'] as List;
    expect(coverage.map((f) => f['path']), [
      'src/app/main.ts',
      'src/core/private.ts',
      'src/generated.ts',
      'src/legacy.js',
      'src/types.d.ts',
    ]);
    expect(coverage[2]['assignment'], 'missing');
    expect(coverage[3]['assignment'], 'unsupported');
    expect(coverage[3]['analysis'], 'not_attempted');
    expect(coverage[4]['assignment'], 'missing');
  });

  test(
    'an exact-file scope operand does not become a directory prefix',
    () async {
      final root = await fixture(
        policy: 'version: 1\nprojects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]\nscope: [src]\nexclude: []\nnodes: []\n',
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.payload['observed'], {
        'files': 0,
        'analyzed_files': 0,
        'edges': 0,
      });
    },
  );

  test(
    'an exact scope entry cannot hide a later directory-prefix entry',
    () async {
      final root = await fixture(
        policy: typescriptPolicy.replaceFirst(
          'scope: [src/]',
          'scope: [src, src/]',
        ),
      );
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.payload['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      });
    },
  );

  test(
    'a declaration containing only type import bindings is type-only',
    () async {
      final root = await fixture(
        main: "import {type Value} from '../core/private';\n",
      );
      await File('${root.path}/src/core/private.ts')
          .writeAsString('export type Value = string;');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(
        ((report.payload['facts'] as Map)['edges'] as List).single['type_only'],
        true,
      );
    },
  );

  test('two compiler memberships remain ambiguous rather than choosing the first project', () async {
    final root = await fixture(
      policy: typescriptPolicy.replaceFirst(
        'scope:',
        '  - id: other\n    adapter: typescript\n    tsconfig: tsconfig.json\nscope:',
      ),
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final rows = (report.payload['coverage'] as Map)['files'] as List;
    expect(
      rows.every(
        (f) =>
            f['assignment'] == 'ambiguous' &&
            f['project_id'] == null &&
            f['context_id'] == null,
      ),
      true,
    );
    expect(rows.first['candidates'], [
      {'project_id': 'other', 'context_id': 'typescript:other'},
      {'project_id': 'web', 'context_id': 'typescript:web'},
    ]);
    expect((report.payload['facts'] as Map)['edges'], hasLength(2));
  });

  test('empty projects and nodes cannot hide existing scoped code', () async {
    final root = await fixture(
      policy:
          'version: 1\nprojects: []\nscope: [src/]\nexclude: []\nnodes: []\n',
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(report.payload['observed'], {
      'files': 2,
      'analyzed_files': 0,
      'edges': 0,
    });
    expect((report.payload['violations'] as List).map((d) => d['code']), [
      'SOURCE_UNOWNED',
      'SOURCE_UNOWNED',
    ]);
    expect((report.payload['unknowns'] as List).map((d) => d['code']), [
      'ANALYSIS_CONTEXT_MISSING',
      'ANALYSIS_CONTEXT_MISSING',
    ]);
  });

  test(
    'target exclusion precedes module permission even for an unowned source',
    () async {
      final policy = typescriptPolicy
          .replaceFirst('exclude: []', 'exclude: [src/core/]')
          .replaceFirst('owns: [src/app/]', 'owns: []');
      final root = await fixture(policy: policy);
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'negative');
      expect(
        (report.payload['violations'] as List).map((d) => d['code']).toSet(),
        {'SOURCE_UNOWNED', 'LOCAL_TARGET_EXCLUDED'},
      );
      expect((report.payload['facts'] as Map)['edges'], hasLength(1));
    },
  );

  test(
    'a relative directory alias does not become unproved local target evidence',
    () async {
      final root = await fixture(
        main: "import {value} from '../alias/private';\n",
        policy: typescriptPolicy.replaceFirst(
          'scope: [src/]',
          'scope: [src/app/, src/core/]',
        ),
      );
      await Link('${root.path}/src/alias').create('${root.path}/src/core');
      final report = await Inspection().check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(
        (report.payload['unknowns'] as List).map((d) => d['code']),
        contains('UNSUPPORTED_TARGET_ORIGIN'),
      );
    },
  );

  test('Inspection uses the same exact public-target predicate as Plan', () async {
    final privatePolicy = typescriptPolicy.replaceFirst(
      'allows: []',
      'allows: [core]',
    );
    final root = await fixture(policy: privatePolicy);
    final denied = await Inspection().check(RepositorySelection(root.path));
    final violation = (denied.payload['violations'] as List).single;
    expect(violation['code'], 'TARGET_NOT_PUBLIC');
    expect(violation['rule_pointer'], '/nodes/1/public');
    await File('${root.path}/architecture.yaml').writeAsString(
      privatePolicy.replaceFirst(
        'owns: [src/core/]\n    allows: []\n    public: []',
        'owns: [src/core/]\n    allows: []\n    public: [src/core/private.ts]',
      ),
    );
    final allowed = await Inspection().check(RepositorySelection(root.path));
    expect(allowed.status, 'ok');
    expect(allowed.payload['violations'], isEmpty);
  });
  test(
    'transparent wrappers do not hide an explicit require reference',
    () async {
      for (final expression in [
        "(require)('../core/private')",
        "require!('../core/private')",
      ]) {
        final root = await fixture(main: '$expression;\n');
        final report = await Inspection().check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        expect(
          (report.payload['unknowns'] as List).map((d) => d['code']),
          contains('UNSUPPORTED_MODULE_REFERENCE'),
        );
      }
    },
  );
}

const typescriptPolicy = """
version: 1
projects:
  - id: web
    adapter: typescript
    tsconfig: tsconfig.json
scope: [src/]
exclude: []
nodes:
  - id: app
    responsibility: Application
    owns: [src/app/]
    allows: []
    public: []
  - id: core
    responsibility: Core
    owns: [src/core/]
    allows: []
    public: []
""";

Future<Directory> fixture({
  String? config,
  String? main,
  String? policy,
}) async {
  final root = await Directory.systemTemp.createTemp('archway-inspection-');
  addTearDown(() => root.delete(recursive: true));
  await Directory('${root.path}/src/app').create(recursive: true);
  await Directory('${root.path}/src/core').create(recursive: true);
  await File('${root.path}/src/app/main.ts').writeAsString(
    main ?? "import {value} from '../core/private';\nconsole.log(value);\n",
  );
  await File('${root.path}/src/core/private.ts')
      .writeAsString('export const value = 1;\n');
  await File('${root.path}/tsconfig.json').writeAsString(
    config ?? '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}',
  );
  await File('${root.path}/architecture.yaml')
      .writeAsString(policy ?? typescriptPolicy);
  return root;
}
