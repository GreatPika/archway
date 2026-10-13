import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'typescript_fixture.dart' show fixture;
import 'physical_paths_test.dart' show checkPhysical;
import 'support/node_package_fixtures.dart';

Future<void> copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entry in source.list(followLinks: false)) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final destination = '${target.path}/$name';
    if (entry is Link) {
      await Link(destination).create(await entry.target());
    } else if (entry is Directory) {
      await copyTree(entry, Directory(destination));
    } else {
      await (entry as File).copy(destination);
    }
  }
}

// The archive contains actual package-manager output and licenses. Extraction
// preserves native directory symlinks and hardlinks; no package code or manager runs.
Future<Directory> preparedFixture(String name, String main) async {
  final scaffold = await fixture(main: main);
  final container = await Directory.systemTemp.createTemp('archway-prepared-');
  final root = Directory('${container.path}/$name');
  addTearDown(() => finishFixture(root, container));
  final archives = ['prepared.tar.gz'];
  if ([
    'pnpm-root-override',
    'pnpm-git',
    'pnpm-hashedfilename',
    'pnpm-parent-snapshot',
  ].contains(name)) {
    archives.add('addon.tar.gz');
  }
  if (name == 'npm-override') archives.add('npm-override.tar.gz');
  for (final archive in archives) {
    await extractNodeFixture(
      File('test/fixtures/node-packages/$archive'),
      container,
    );
  }
  for (final file in ['architecture.yaml']) {
    await File('${scaffold.path}/$file').copy('${root.path}/$file');
  }
  await copyTree(
    Directory('${scaffold.path}/src'),
    Directory('${root.path}/src'),
  );
  final entry = File('${root.path}/src/index.ts');
  if (await entry.exists()) await entry.delete();
  return root;
}

final _pendingInspections = <String, List<Future<dynamic>>>{};

Future<T> trackInspection<T>(Directory root, Future<T> pending) {
  (_pendingInspections[root.path] ??= []).add(pending);
  return pending;
}

Future<void> finishFixture(
  Directory root,
  Directory container, {
  Duration timeout = const Duration(seconds: 130),
}) async {
  final pending = _pendingInspections.remove(root.path) ?? [];
  // Allow the existing 5s preflight + 120s helper + 2s reap to finish.
  // On failure or an unconfirmed deadline, preserve the fixture and fail.
  await Future.wait(pending).timeout(timeout);
  await container.delete(recursive: true);
}

Future<dynamic> check(Directory root) =>
    trackInspection(root, Inspection().check(RepositorySelection(root.path)));
List<dynamic> edges(dynamic report) => report.payload['facts']['edges'] as List;
void complete(dynamic report) => expect(
  report.payload['analysis_complete'],
  true,
  reason: '${report.payload['tool_errors']} ${report.payload['unknowns']}',
);

void main() {
  test('fixture cleanup waits for an already-started inspection', () async {
    final container = await Directory.systemTemp.createTemp('archway-cleanup-');
    final root = Directory('${container.path}/project');
    final pending = Completer<void>();
    trackInspection(root, pending.future);
    final cleanup = finishFixture(root, container);
    await Future<void>.delayed(Duration.zero);
    expect(await container.exists(), isTrue);
    pending.complete();
    await cleanup;
    expect(await container.exists(), isFalse);
  });
  test('fixture cleanup preserves inputs when inspection fails', () async {
    final container = await Directory.systemTemp.createTemp('archway-cleanup-');
    addTearDown(() => container.delete(recursive: true));
    final root = Directory('${container.path}/project');
    final failure = StateError('inspection failed');
    trackInspection(root, Future<void>.error(failure));
    await expectLater(finishFixture(root, container), throwsA(same(failure)));
    expect(await container.exists(), isTrue);
  });
  test('fixture cleanup is bounded and preserves unfinished inputs', () async {
    final container = await Directory.systemTemp.createTemp('archway-cleanup-');
    addTearDown(() => container.delete(recursive: true));
    final root = Directory('${container.path}/project');
    final pending = Completer<void>();
    trackInspection(root, pending.future);
    await expectLater(
      finishFixture(root, container, timeout: Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    expect(await container.exists(), isTrue);
    pending.complete();
    await pending.future;
  });
  test(
    'real npm v3 registry installation is external inside repository',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import ansiRegex from 'ansi-regex';\n",
      );
      final report = await check(root);
      expect(report.status, 'ok', reason: jsonEncode(report.payload));
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': 'npm:ansi-regex@6.1.0',
      });
    },
  );
  test(
    'npm origin joins the nearest importer and still requires its lock row',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\nimport '../core/private.js';\n",
      );
      final importer = {
        'name': 'nested-importer',
        'private': true,
        'dependencies': {'ansi-regex': '6.1.0'},
      };
      await File('${root.path}/src/app/package.json')
          .writeAsString(jsonEncode(importer));
      final manifestFile = File('${root.path}/package.json');
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
      manifest['dependencies']['ansi-regex'] = 'file:../contradictory';
      await manifestFile.writeAsString(jsonEncode(manifest));
      final lockFile = File('${root.path}/package-lock.json');
      final lock = jsonDecode(await lockFile.readAsString()) as Map;
      lock['packages']['']['dependencies'] = manifest['dependencies'];
      lock['packages']['src/app'] = importer;
      await lockFile.writeAsString(jsonEncode(lock));

      final report = await check(root);
      complete(report);
      expect(report.status, 'negative');
      expect(edges(report).first['resolution'], {
        'kind': 'external',
        'identity': 'npm:ansi-regex@6.1.0',
      });
      expect(edges(report).last['resolution']['kind'], 'local');
      expect(
        report.payload['violations'],
        contains(
          predicate((dynamic v) => v['code'] == 'DEPENDENCY_NOT_ALLOWED'),
        ),
      );

      lock['packages'].remove('src/app');
      await lockFile.writeAsString(jsonEncode(lock));
      final missing = await check(root);
      expect(missing.status, 'incomplete');
      expect(edges(missing).first['resolution']['kind'], 'unresolved');
      expect(edges(missing).last['resolution']['kind'], 'local');
    },
  );
  test('real npm workspace target retains local provenance', () async {
    final root = await preparedFixture(
      'npm-workspace',
      "import {localFixture} from 'archway-local-types';\n",
    );
    final report = await check(root);
    expect(edges(report).single['resolution']['kind'], 'local');
    expect(
      edges(report).single['resolution']['path'],
      'packages/local/index.d.ts',
    );
    complete(report);
  });
  test('real npm copied file directory remains local', () async {
    final root = await preparedFixture(
      'npm-file',
      "import {outsideFixture} from 'archway-outside-types';\n",
    );
    final report = await check(root);
    expect(edges(report).single['resolution']['kind'], 'local');
    complete(report);
  });
  test('contradictory effective local source never becomes external', () async {
    final root = await preparedFixture(
      'npm-v3-small',
      "import ansiRegex from 'ansi-regex';\n",
    );
    final file = File('${root.path}/package.json');
    final manifest = jsonDecode(await file.readAsString()) as Map;
    manifest['dependencies']['ansi-regex'] = 'file:../outside-local';
    await file.writeAsString(jsonEncode(manifest));
    final report = await check(root);
    expect(report.status, 'incomplete');
    expect(edges(report).single['resolution']['kind'], 'unresolved');
  });
  test('real pnpm v9 registry instance is external', () async {
    final root = await preparedFixture(
      'pnpm-registry',
      "import ansiRegex from 'ansi-regex';\n",
    );
    final report = await check(root);
    expect(edges(report).single['resolution'], {
      'kind': 'external',
      'identity': 'pnpm:ansi-regex@6.1.0',
    }, reason: jsonEncode(report.payload));
    complete(report);
  });
  test(
    'real pnpm peer snapshot retains its complete instance identity',
    () async {
      final root = await preparedFixture(
        'pnpm-peer',
        "import type {Root} from 'react-dom/client';\n",
      );
      final report = await check(root);
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': 'pnpm:@types/react-dom@19.0.4(@types/react@19.0.12)',
      });
      complete(report);
    },
  );
  test('real pnpm injected workspace copy stays local', () async {
    final root = await preparedFixture(
      'pnpm-injected',
      "import {localFixture} from 'archway-local-types';\n",
    );
    final report = await check(root);
    expect(edges(report).single['resolution']['kind'], 'local');
    expect(
      edges(report).single['resolution']['path'],
      contains('archway-local-types@file+packages+local_ansi-regex@6.1.0'),
    );
    complete(report);
  });
  test(
    'real Node ambient require proves a package already in the Program',
    () async {
      final root = await preparedFixture(
        'npm-ambient-node',
        "import ansiRegex from 'ansi-regex';\nrequire('ansi-regex');\n",
      );
      final report = await check(root);
      expect(
        edges(report).where((e) => e['kind'] == 'require').single['resolution'],
        {'kind': 'external', 'identity': 'npm:ansi-regex@6.1.0'},
      );
      complete(report);
    },
  );
  test(
    'real Node ambient builtin declarations prove import and require',
    () async {
      final root = await preparedFixture(
        'npm-ambient-node',
        "import {readFileSync} from 'node:fs';\nrequire('fs');\n",
      );
      final report = await check(root);
      expect(edges(report), hasLength(2));
      for (final edge in edges(report)) {
        expect(edge['resolution'], {'kind': 'builtin', 'identity': 'node:fs'});
      }
      expect(report.status, 'ok');
    },
  );
  test('compiler-proven lockless self export remains local', () async {
    final root = await fixture(
      main: "import {value} from 'archway-self/private';\n",
      config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*.ts"]}',
    );
    await File('${root.path}/package.json').writeAsString(
      jsonEncode({
        'name': 'archway-self',
        'version': '1.0.0',
        'exports': {
          './private': {'types': './src/core/private.ts'},
        },
      }),
    );
    final report = await check(root);
    expect(edges(report).single['resolution']['kind'], 'local');
    expect(edges(report).single['resolution']['path'], 'src/core/private.ts');
    expect(report.status, 'negative');
  });
  test('real npm pinned remote Git instance is external', () async {
    final root = await preparedFixture(
      'npm-git',
      "import ansiRegex from 'ansi-regex';\n",
    );
    final report = await check(root);
    expect(edges(report).single['resolution'], {
      'kind': 'external',
      'identity': 'npm:ansi-regex@6.1.0',
    });
    expect(report.status, 'ok');
  });
  test('real pnpm workspace link stays local', () async {
    final root = await preparedFixture(
      'pnpm-workspace',
      "import {localFixture} from 'archway-local-types';\n",
    );
    final report = await check(root);
    expect(edges(report).single['resolution']['kind'], 'local');
    expect(
      edges(report).single['resolution']['path'],
      'packages/local/index.d.ts',
    );
    complete(report);
  });
  for (final entry in {
    'npm-v2': 'npm:ansi-regex@6.1.0',
    'npm-alias': 'npm:ansi-regex@6.1.0',
    'npm-tarball': 'npm:ansi-regex@6.1.0',
    'npm-shrinkwrap': 'npm:ansi-regex@6.1.0',
    'pnpm-alias': 'pnpm:ansi-regex@6.1.0',
    'pnpm-tarball': 'pnpm:ansi-regex@6.1.0',
    'pnpm-moved': 'pnpm:ansi-regex@6.1.0',
    'pnpm-hashedpeer':
        'pnpm:@types/react-dom@19.0.4(jc3r24zgonp253s3uzs32xbkcu)',
  }.entries) {
    test('prepared ${entry.key} proves its exact external instance', () async {
      final specifier = entry.key.contains('alias')
          ? 'fixture-alias'
          : entry.key.contains('peer')
          ? 'react-dom/client'
          : 'ansi-regex';
      final root = await preparedFixture(entry.key, "import '$specifier';\n");
      if (entry.key == 'npm-shrinkwrap')
        await File('${root.path}/package-lock.json')
            .writeAsString('{"lockfileVersion":99}');
      final report = await check(root);
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': entry.value,
      });
      complete(report);
    });
  }
  for (final name in ['npm-path', 'pnpm-path', 'pnpm-file']) {
    test('prepared $name retains local path provenance', () async {
      final root = await preparedFixture(
        name,
        "import 'archway-outside-types';\n",
      );
      final report = await check(root);
      expect(edges(report).single['resolution']['kind'], 'local');
      if (name.endsWith('path')) {
        expect(edges(report).single['resolution']['path'], isNull);
        expect(
          report.payload['violations'],
          contains(
            predicate((dynamic v) => v['code'] == 'LOCAL_TARGET_OUTSIDE_SCOPE'),
          ),
        );
      }
      complete(report);
    });
  }

  test(
    'relative installed import remains external under broad ownership',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import '../../node_modules/ansi-regex/index.js';\n",
      );
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]\nscope: [src/]\nexclude: []\nnodes: [{id: all, responsibility: All, owns: [./], allows: [], public: []}]\n',
      );
      final report = await check(root);
      expect(edges(report).single['resolution']['kind'], 'external');
      expect(report.status, 'ok');
    },
  );
  test('missing or conflicting npm metadata retains an independent violation', () async {
    for (final mutation in ['missing', 'version', 'alias']) {
      final root = await preparedFixture(
        mutation == 'alias' ? 'npm-alias' : 'npm-v3-small',
        "import '${mutation == 'alias' ? 'fixture-alias' : 'ansi-regex'}';\nimport '../core/private.js';\n",
      );
      final file = File('${root.path}/package-lock.json');
      if (mutation == 'missing') {
        await file.delete();
      } else {
        final lock = jsonDecode(await file.readAsString()) as Map;
        lock['packages']['node_modules/${mutation == 'alias' ? 'fixture-alias' : 'ansi-regex'}'][mutation ==
                    'alias'
                ? 'name'
                : 'version'] =
            'contradictory';
        await file.writeAsString(jsonEncode(lock));
      }
      final report = await check(root);
      expect(report.status, 'incomplete');
      expect(
        edges(report).map((e) => e['resolution']['kind']),
        containsAll(['unresolved', 'local']),
      );
      expect(
        report.payload['violations'],
        contains(
          predicate((dynamic v) => v['code'] == 'DEPENDENCY_NOT_ALLOWED'),
        ),
      );
    }
  });
  for (final mutation in [
    'missing',
    'duplicate',
    'tag',
    'installed',
    'version',
    'layout',
  ]) {
    test('invalid or stale pnpm join remains incomplete: $mutation', () async {
      final root = await preparedFixture(
        'pnpm-registry',
        "import 'ansi-regex';\n",
      );
      final lock = File('${root.path}/pnpm-lock.yaml');
      if (mutation == 'missing') {
        await lock.delete();
      }
      if (mutation == 'duplicate')
        await lock.writeAsString(
          'lockfileVersion: 9.0\n',
          mode: FileMode.append,
        );
      if (mutation == 'tag')
        await lock.writeAsString(
          'custom: !execute arbitrary\n',
          mode: FileMode.append,
        );
      if (mutation == 'installed')
        await File('${root.path}/node_modules/.pnpm/lock.yaml')
            .writeAsString("lockfileVersion: '9.0'\n");
      if (mutation == 'version') {
        final manifest = File(
          '${root.path}/node_modules/ansi-regex/package.json',
        );
        final value = jsonDecode(await manifest.readAsString()) as Map;
        value['version'] = '0.0.0';
        await manifest.writeAsString(jsonEncode(value));
      }
      if (mutation == 'layout') {
        final modules = File('${root.path}/node_modules/.modules.yaml');
        await modules.writeAsString(
          (await modules.readAsString()).replaceFirst(
            'layoutVersion: 5',
            'layoutVersion: 99',
          ),
        );
      }
      final report = await check(root);
      expect(report.status, 'incomplete', reason: mutation);
      expect(
        edges(report).single['resolution']['kind'],
        'unresolved',
        reason: mutation,
      );
    });
  }
  for (final binding in {
    'augmented require signature': "export {}; declare global { namespace NodeJS { interface Require { (x: number): string; } } } require('fs');\n",
    'augmented node module': "import 'node:fs'; declare module 'node:fs' { export const forged: string; }\n",
    'local require binding':
        "const require = (x:string)=>42; require('fs'); export {};\n",
    'unproven package require': "require('ansi-regex');\n",
  }.entries) {
    test(
      'Node binding cannot borrow builtin provenance: ${binding.key}',
      () async {
        final root = await preparedFixture('npm-ambient-node', binding.value);
        final report = await check(root);
        expect(report.status, 'incomplete', reason: binding.value);
        expect(
          edges(report).where((e) => e['resolution']['kind'] == 'builtin'),
          isEmpty,
          reason: binding.key,
        );
      },
    );
  }

  for (final entry in {
    'npm-v3-small': [
      'package-lock.json',
      'package.json',
      'node_modules/ansi-regex/package.json',
      'npm-shrinkwrap.json',
    ],
    'pnpm-registry': [
      'pnpm-lock.yaml',
      'node_modules/.modules.yaml',
      'node_modules/.pnpm/lock.yaml',
      'node_modules/ansi-regex/package.json',
    ],
    'pnpm-injected': ['pnpm-workspace.yaml', 'packages/local/package.json'],
  }.entries) {
    for (final relative in entry.value) {
      test(
        'classifier mutation retains baseline facts: ${entry.key}/$relative',
        () async {
          final specifier = entry.key == 'pnpm-injected'
              ? 'archway-local-types'
              : 'ansi-regex';
          final root = await preparedFixture(
            entry.key,
            "import '$specifier';\nimport '../core/private.js';\n",
          );
          var mutated = false;
          final report = await trackInspection(
            root,
            runZoned(
              () => checkPhysical(root, 2),
              zoneValues: {
                #archwayBeforeInputRecheck: () {
                  final file = File('${root.path}/$relative');
                  file.writeAsStringSync(
                    file.existsSync() ? file.readAsStringSync() + '\n' : '{}',
                  );
                  mutated = true;
                },
              },
            ),
          );
          expect(mutated, true);
          final payload = report['payload'];
          expect(payload['analysis_complete'], false);
          expect(payload['tool_errors'], isEmpty, reason: relative);
          expect(
            payload['unknowns'],
            contains(predicate((dynamic u) => u['code'] == 'INPUT_CHANGED')),
            reason: relative,
          );
          expect(payload['facts']['edges'], hasLength(2), reason: relative);
          expect(
            payload['violations'],
            contains(
              predicate((dynamic v) => v['code'] == 'DEPENDENCY_NOT_ALLOWED'),
            ),
          );
        },
      );
    }
  }
  test('package CLI reports complete schema-one JSON and exact exit streams', () async {
    for (final entry in {'npm-v3-small': 0, 'npm-path': 1}.entries) {
      final root = await preparedFixture(
        entry.key,
        "import '${entry.key == 'npm-path' ? 'archway-outside-types' : 'ansi-regex'}';\n",
      );
      final report = await checkPhysical(root, entry.value);
      expect(report['payload']['analysis_complete'], true);
      expect(report['tool_versions']['typescript'], '5.9.3');
    }
  });

  test(
    'effective pnpm root override proves a hosted-looking dependency local',
    () async {
      final root = await preparedFixture(
        'pnpm-root-override',
        "import 'archway-outside-types';\n",
      );
      final report = await check(root);
      expect(edges(report).single['resolution']['kind'], 'local');
      complete(report);
    },
  );

  test(
    'real pnpm remote Git tarball normalization retains external origin',
    () async {
      final root = await preparedFixture('pnpm-git', "import 'ansi-regex';\n");
      final report = await check(root);
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': 'pnpm:ansi-regex@6.1.0',
      });
      complete(report);
    },
  );

  test('pnpm transitive source joins its parent snapshot dependency reference', () async {
    final root = await preparedFixture(
      'pnpm-parent-snapshot',
      "import 'react';\n",
    );
    const source =
        'node_modules/.pnpm/@types+react@19.0.12/node_modules/@types/react/index.d.ts';
    await File('${root.path}/architecture.yaml').writeAsString(
      'version: 1\nprojects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]\nscope: [$source]\nexclude: []\nnodes: [{id: source, responsibility: Declarations, owns: [$source], allows: [], public: []}]\n',
    );
    final report = await check(root);
    final edge = edges(report).singleWhere((e) => e['specifier'] == 'csstype');
    expect(edge['resolution'], {
      'kind': 'external',
      'identity': 'pnpm:csstype@3.2.3',
    });
  });

  test(
    'unrelated npm override cannot erase proven dependency provenance',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\n",
      );
      final file = File('${root.path}/package.json');
      final value = jsonDecode(await file.readAsString()) as Map;
      value['overrides'] = {'unrelated-package': 'file:../outside-local'};
      await file.writeAsString(jsonEncode(value));
      final report = await check(root);
      expect(edges(report).single['resolution']['kind'], 'external');
      complete(report);
    },
  );

  test('npm copied local row must agree with the effective directory source', () async {
    final root = await preparedFixture(
      'npm-file',
      "import 'archway-outside-types';\n",
    );
    for (final name in ['package.json', 'package-lock.json']) {
      final file = File('${root.path}/$name');
      final value = jsonDecode(await file.readAsString()) as Map;
      (name == 'package.json'
              ? value
              : value['packages'][''])['dependencies']['archway-outside-types'] =
          '1.0.0';
      await file.writeAsString(jsonEncode(value));
    }
    final report = await check(root);
    expect(report.status, 'incomplete');
    expect(edges(report).single['resolution']['kind'], 'unresolved');
  });

  test(
    'excluded pnpm workspace member cannot use stale injected provenance',
    () async {
      final root = await preparedFixture(
        'pnpm-injected',
        "import 'archway-local-types';\n",
      );
      await File('${root.path}/pnpm-workspace.yaml')
          .writeAsString("packages:\n  - packages/*\n  - '!packages/local'\n");
      final report = await check(root);
      expect(report.status, 'incomplete');
      expect(edges(report).single['resolution']['kind'], 'unresolved');
    },
  );

  test(
    'npm link row requires effective workspace membership or local source',
    () async {
      final root = await preparedFixture(
        'npm-workspace',
        "import 'archway-local-types';\n",
      );
      final file = File('${root.path}/package.json');
      final value = jsonDecode(await file.readAsString()) as Map;
      value.remove('workspaces');
      await file.writeAsString(jsonEncode(value));
      final report = await check(root);
      expect(report.status, 'incomplete');
      expect(edges(report).single['resolution']['kind'], 'unresolved');
    },
  );
  test(
    'real pnpm shortened filename verifies the upstream hash encoder',
    () async {
      final root = await preparedFixture(
        'pnpm-hashedfilename',
        "import 'react-dom/client';\n",
      );
      final report = await check(root);
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': 'pnpm:@types/react-dom@19.0.4(@types/react@19.0.12)',
      });
      complete(report);
    },
  );

  test(
    'compiler self-export wildcard still maps to the final target',
    () async {
      final root = await fixture(
        main: "import 'self-map/core/private';\n",
        config: '{"compilerOptions":{"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*.ts"]}',
      );
      await File('${root.path}/package.json').writeAsString(
        jsonEncode({
          'name': 'self-map',
          'version': '1.0.0',
          'exports': {'./*': './src/*.ts'},
        }),
      );
      final report = await check(root);
      expect(edges(report).single['resolution']['kind'], 'local');
      expect(report.status, 'negative');
    },
  );

  test(
    'pnpm metadata object order does not alter an exact installed join',
    () async {
      final root = await preparedFixture(
        'pnpm-registry',
        "import 'ansi-regex';\n",
      );
      final file = File('${root.path}/pnpm-lock.yaml');
      await file.writeAsString(
        (await file.readAsString()).replaceFirst(
          'specifier: 6.1.0\n        version: 6.1.0',
          'version: 6.1.0\n        specifier: 6.1.0',
        ),
      );
      final report = await check(root);
      expect(edges(report).single['resolution']['kind'], 'external');
      complete(report);
    },
  );
  test(
    'effective version requests must agree with the installed package',
    () async {
      for (final manager in ['npm', 'pnpm']) {
        final root = await preparedFixture(
          manager == 'npm' ? 'npm-v3-small' : 'pnpm-registry',
          "import 'ansi-regex';\n",
        );
        final file = File('${root.path}/package.json');
        final value = jsonDecode(await file.readAsString()) as Map;
        if (manager == 'npm') {
          value['overrides'] = {'ansi-regex': '99.0.0'};
        } else {
          value['dependencies']['ansi-regex'] = '99.0.0';
        }
        await file.writeAsString(jsonEncode(value));
        if (manager == 'pnpm') {
          for (final name in [
            'pnpm-lock.yaml',
            'node_modules/.pnpm/lock.yaml',
          ]) {
            final lock = File('${root.path}/$name');
            await lock.writeAsString(
              (await lock.readAsString()).replaceFirst(
                'specifier: 6.1.0',
                'specifier: 99.0.0',
              ),
            );
          }
        }
        final report = await check(root);
        expect(report.status, 'incomplete', reason: manager);
        expect(
          edges(report).single['resolution']['kind'],
          'unresolved',
          reason: manager,
        );
      }
    },
  );
  test(
    'npm registry installation stays external through an outside store route',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\n",
      );
      final outside = '${root.parent.path}/outside-installation';
      await Directory('${root.path}/node_modules').rename(outside);
      await Link('${root.path}/node_modules').create(outside);
      final report = await check(root);
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': 'npm:ansi-regex@6.1.0',
      });
      expect(report.status, 'ok');
    },
  );

  test(
    'real npm dependency-referenced override preserves valid precedence',
    () async {
      final root = await preparedFixture(
        'npm-override',
        "import 'ansi-regex';\n",
      );
      final report = await check(root);
      expect(edges(report).single['resolution'], {
        'kind': 'external',
        'identity': 'npm:ansi-regex@6.1.0',
      });
      complete(report);
    },
  );
  test('npm pinned Git request cannot reuse a registry row', () async {
    final root = await preparedFixture(
      'npm-v3-small',
      "import 'ansi-regex';\n",
    );
    const source =
        'git+https://github.com/example/different.git#1111111111111111111111111111111111111111';
    for (final name in ['package.json', 'package-lock.json']) {
      final file = File('${root.path}/$name');
      final value = jsonDecode(await file.readAsString()) as Map;
      final importer = name == 'package.json' ? value : value['packages'][''];
      importer['dependencies']['ansi-regex'] = source;
      await file.writeAsString(jsonEncode(value));
    }
    final report = await check(root);
    expect(report.status, 'incomplete');
    expect(edges(report).single['resolution']['kind'], 'unresolved');
  });

  test('npm illegal direct override cannot erase a local request', () async {
    final root = await preparedFixture(
      'npm-v3-small',
      "import 'ansi-regex';\n",
    );
    for (final name in ['package.json', 'package-lock.json']) {
      final file = File('${root.path}/$name');
      final value = jsonDecode(await file.readAsString()) as Map;
      final importer = name == 'package.json' ? value : value['packages'][''];
      importer['dependencies']['ansi-regex'] = 'file:../outside-local';
      if (name == 'package.json') value['overrides'] = {'ansi-regex': '6.1.0'};
      await file.writeAsString(jsonEncode(value));
    }
    final report = await check(root);
    expect(report.status, 'incomplete');
    expect(edges(report).single['resolution']['kind'], 'unresolved');
  });

  test(
    'present null npm shrinkwrap cannot fall back to package lock',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\n",
      );
      await File('${root.path}/npm-shrinkwrap.json').writeAsString('null');
      final report = await check(root);
      expect(report.status, 'incomplete');
      expect(edges(report).single['resolution']['kind'], 'unresolved');
    },
  );

  test('pnpm registry resolution rejects conflicting discriminators', () async {
    for (final discriminator in [
      'tarball: "file:../local.tgz", ',
      'type: mystery, ',
    ]) {
      final root = await preparedFixture(
        'pnpm-registry',
        "import 'ansi-regex';\nimport './kept.js';\n",
      );
      await File('${root.path}/src/app/kept.ts')
          .writeAsString('export const kept = true;\n');
      for (final name in ['pnpm-lock.yaml', 'node_modules/.pnpm/lock.yaml']) {
        final file = File('${root.path}/$name');
        await file.writeAsString(
          (await file.readAsString()).replaceFirst(
            'resolution: {integrity:',
            'resolution: {$discriminator'
                'integrity:',
          ),
        );
      }
      final report = await check(root);
      expect(
        edges(report).singleWhere(
          (e) => e['specifier'] == './kept.js',
        )['resolution']['kind'],
        'local',
      );
      expect(
        edges(report).singleWhere(
          (e) => e['specifier'] == 'ansi-regex',
        )['resolution']['kind'],
        'unresolved',
      );
    }
  });

  test(
    'pnpm effective remote source must agree with registry resolution',
    () async {
      for (final source in [
        'git+file:///tmp/local-repository#0123456789012345678901234567890123456789',
        'https://example.org/different-origin.tgz',
      ]) {
        final root = await preparedFixture(
          'pnpm-registry',
          "import 'ansi-regex';\nimport './kept.js';\n",
        );
        await File('${root.path}/src/app/kept.ts')
            .writeAsString('export const kept = true;\n');
        final file = File('${root.path}/package.json');
        final manifest = jsonDecode(await file.readAsString()) as Map;
        manifest['dependencies']['ansi-regex'] = source;
        await file.writeAsString(jsonEncode(manifest));
        for (final name in ['pnpm-lock.yaml', 'node_modules/.pnpm/lock.yaml']) {
          final file = File('${root.path}/$name');
          await file.writeAsString(
            (await file.readAsString()).replaceFirst(
              'specifier: 6.1.0',
              'specifier: "$source"',
            ),
          );
        }
        final report = await check(root);
        expect(
          edges(report).singleWhere(
            (e) => e['specifier'] == './kept.js',
          )['resolution']['kind'],
          'local',
        );
        expect(
          edges(report).singleWhere(
            (e) => e['specifier'] == 'ansi-regex',
          )['resolution']['kind'],
          'unresolved',
        );
      }
    },
  );

  test(
    'classifier lock alias retarget detects identical metadata bytes',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\nimport '../core/private.js';\n",
      );
      final lock = File('${root.path}/package-lock.json');
      final first = '${root.path}/first-lock.json';
      final second = '${root.path}/second-lock.json';
      await lock.copy(first);
      await lock.copy(second);
      await lock.delete();
      await Link(lock.path).create(first);
      final report = await runZoned(
        () => checkPhysical(root, 2),
        zoneValues: {
          #archwayBeforeInputRecheck: () {
            Link(lock.path).deleteSync();
            Link(lock.path).createSync(second);
          },
        },
      );
      final payload = report['payload'];
      expect(payload['analysis_complete'], false);
      expect(payload['tool_errors'], isEmpty);
      expect(
        payload['unknowns'],
        contains(predicate((dynamic u) => u['code'] == 'INPUT_CHANGED')),
      );
      expect(payload['facts']['edges'], hasLength(2));
      expect(
        payload['violations'],
        contains(
          predicate((dynamic v) => v['code'] == 'DEPENDENCY_NOT_ALLOWED'),
        ),
      );
    },
  );
  test(
    'npm referenced direct override also requires exact effective spec',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\n",
      );
      for (final name in ['package.json', 'package-lock.json']) {
        final file = File('${root.path}/$name');
        final value = jsonDecode(await file.readAsString()) as Map;
        final importer = name == 'package.json' ? value : value['packages'][''];
        importer['dependencies']['ansi-regex'] = 'file:../outside-local';
        importer['dependencies']['other'] = '6.1.0';
        if (name == 'package.json')
          value['overrides'] = {'ansi-regex': r'$other'};
        await file.writeAsString(jsonEncode(value));
      }
      final report = await check(root);
      expect(report.status, 'incomplete');
      expect(edges(report).single['resolution']['kind'], 'unresolved');
    },
  );
  test(
    'pnpm registry URL normalization cannot erase an explicit tarball',
    () async {
      final root = await preparedFixture(
        'pnpm-registry',
        "import 'ansi-regex';\nimport './kept.js';\n",
      );
      await File('${root.path}/src/app/kept.ts')
          .writeAsString('export const kept = true;\n');
      const source =
          'https://registry.npmjs.org/ansi-regex/-/ansi-regex-6.1.0.tgz';
      final file = File('${root.path}/package.json');
      final manifest = jsonDecode(await file.readAsString()) as Map;
      manifest['dependencies']['ansi-regex'] = source;
      await file.writeAsString(jsonEncode(manifest));
      for (final name in ['pnpm-lock.yaml', 'node_modules/.pnpm/lock.yaml']) {
        final lock = File('${root.path}/$name');
        await lock.writeAsString(
          (await lock.readAsString())
              .replaceFirst('specifier: 6.1.0', 'specifier: "$source"')
              .replaceFirst(
                'resolution: {integrity:',
                'resolution: {tarball: "https://example.org/contradictory.tgz", integrity:',
              ),
        );
      }
      final report = await check(root);
      expect(
        edges(report).singleWhere(
          (e) => e['specifier'] == './kept.js',
        )['resolution']['kind'],
        'local',
      );
      expect(
        edges(report).singleWhere(
          (e) => e['specifier'] == 'ansi-regex',
        )['resolution']['kind'],
        'unresolved',
      );
    },
  );
}
