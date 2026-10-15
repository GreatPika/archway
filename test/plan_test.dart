import 'dart:io';
import 'dart:convert';

import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

void main() {
  test('loads exact empty policy bytes with counts and EMPTY_PLAN warning', () async {
    final root = await Directory.systemTemp.createTemp('archway-plan-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/architecture.yaml').writeAsString(
      'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
    );
    final result = await Plan.load(RepositorySelection(root.path));
    expect(
      result.status,
      'ok',
      reason: result.diagnostics
          .map((d) => '${d.code}:${d.message}:${d.rulePointer}')
          .join(';'),
    );
    expect(result.plan!.projectCount, 0);
    expect(result.plan!.nodeCount, 0);
    expect(
      result.policyHash,
      'sha256:dd24d440ea8b75a3cce173d5740155e0f2e9d8387fd9c0410b5a5664ad23c95b',
    );
    expect(result.diagnostics.single.code, 'EMPTY_PLAN');
    expect(result.diagnostics.single.severity, 'warning');
  });
  test(
    'owns future paths lexically with exclusion and scope precedence',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': ['src/'],
        'exclude': ['src/app/generated/'],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'Compose app',
            'owns': ['src/app/', 'outside/'],
            'public': [],
            'allows': [],
          },
        ],
      });
      expect(
        result.status,
        'ok',
        reason: result.diagnostics
            .map((d) => '${d.code}:${d.message}:${d.rulePointer}')
            .join(';'),
      );
      expect(result.plan!.owner(r'./src\app\future.ts').toJson(), {
        'path': 'src/app/future.ts',
        'ownership': 'owned',
        'owner_id': 'app',
      });
      expect(
        result.plan!.owner('src/app/generated/a.ts').ownership,
        'excluded',
      );
      expect(result.plan!.owner('outside/a.ts').ownership, 'outside_scope');
      expect(result.plan!.owner('src/app2/a.ts').ownership, 'unowned');
      expect(result.diagnostics, isEmpty);
    },
  );
  test('rejects overlapping future ownership even when excluded', () async {
    final result = await loadPolicy({
      'version': 1,
      'projects': [],
      'scope': [],
      'exclude': ['./'],
      'nodes': [
        {
          'id': 'app',
          'responsibility': 'App',
          'owns': ['src/'],
          'public': [],
          'allows': [],
        },
        {
          'id': 'core',
          'responsibility': 'Core',
          'owns': ['src/future.ts'],
          'public': [],
          'allows': [],
        },
      ],
    });
    expect(result.status, 'invalid_policy');
    expect(result.diagnostics.single.code, 'OWNERSHIP_OVERLAP');
    expect(result.diagnostics.single.rulePointer, '/nodes/1/owns/0');
  });
  test(
    'node detail returns normalized direct context without transitive grants',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': ['./'],
        'exclude': [],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'App',
            'owns': ['src/app/', 'src/app/a.ts', 'src/app/'],
            'public': ['src/app/index.ts'],
            'allows': ['core', 'app', 'core'],
          },
          {
            'id': 'core',
            'responsibility': 'Core',
            'owns': ['src/core/'],
            'public': [],
            'allows': ['data'],
          },
          {
            'id': 'data',
            'responsibility': 'Data',
            'owns': [],
            'public': [],
            'allows': [],
          },
        ],
      });
      expect(result.status, 'ok');
      expect(result.plan!.node('app'), {
        'id': 'app',
        'responsibility': 'App',
        'owns': ['src/app/'],
        'public': ['src/app/index.ts'],
        'contracts': [],
        'allows': [
          {'id': 'core', 'responsibility': 'Core'},
        ],
        'allowed_dependents': [],
      });
      expect(result.plan!.node('data')!['allowed_dependents'], [
        {'id': 'core', 'responsibility': 'Core'},
      ]);
      expect(result.plan!.node('absent'), isNull);
    },
  );
  test(
    'public declarations reject directory intent before lexical normalization',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': ['./'],
        'exclude': [],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'App',
            'owns': ['src/'],
            'public': ['src/a/..'],
            'allows': [],
          },
        ],
      });
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.code, 'PUBLIC_PATH_NOT_FILE');
      expect(result.diagnostics.single.rulePointer, '/nodes/0/public/0');
    },
  );
  test(
    'public files must be owned in scope and exclusion has precedence',
    () async {
      for (final entry in {
        'src/private/a.ts': 'PUBLIC_PATH_EXCLUDED',
        'outside/a.ts': 'PUBLIC_PATH_OUTSIDE_SCOPE',
        'src/other/a.ts': 'PUBLIC_PATH_NOT_OWNED',
      }.entries) {
        final result = await loadPolicy({
          'version': 1,
          'projects': [],
          'scope': ['src/'],
          'exclude': ['src/private/'],
          'nodes': [
            {
              'id': 'app',
              'responsibility': 'App',
              'owns': ['src/app/'],
              'public': [entry.key],
              'allows': [],
            },
          ],
        });
        expect(result.status, 'invalid_policy');
        expect(result.diagnostics.single.code, entry.value);
        expect(result.diagnostics.single.rulePointer, '/nodes/0/public/0');
      }
    },
  );
  test(
    'invalid nested lexical paths report their original policy pointer',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [
          {
            'id': 'app',
            'adapter': 'typescript',
            'tsconfig': 'a/../../tsconfig.json',
          },
        ],
        'scope': [],
        'exclude': [],
        'nodes': [],
      });
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.code, 'POLICY_PATH_INVALID');
      expect(result.diagnostics.single.rulePointer, '/projects/0/tsconfig');
    },
  );
  test(
    'file permission needs a direct grant and exact target public file',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': ['src/'],
        'exclude': [],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'App',
            'owns': ['src/app/'],
            'public': [],
            'allows': ['core'],
          },
          {
            'id': 'core',
            'responsibility': 'Core',
            'owns': ['src/core/'],
            'public': ['src/core/api'],
            'allows': ['data'],
          },
          {
            'id': 'data',
            'responsibility': 'Data',
            'owns': ['src/data/'],
            'public': ['src/data/api'],
            'allows': [],
          },
        ],
      });
      final plan = result.plan!;
      expect(plan.allows('app', 'data').reason, 'not_allowed');
      expect(plan.allows('core', 'data').reason, 'declared_allow');
      expect(plan.allows('app', 'app').reason, 'same_owner');
      expect(
        plan.allowsPaths('src/app/new', 'src/core/api').decision,
        'allowed',
      );
      expect(
        plan.allowsPaths('src/app/new', 'src/core/private').reason,
        'target_not_public',
      );
      expect(
        plan.allowsPaths('src/core/a', 'src/core/private').reason,
        'same_owner',
      );
      expect(
        plan.allowsPaths('src/app/a', 'src/data/private').reason,
        'not_allowed',
      );
      expect(
        plan.allowsPaths('src/unowned/a', 'src/core/api').decision,
        'undetermined',
      );
    },
  );
  test(
    'unknown permission targets fail at the original allows pointer',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': [],
        'exclude': [],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'App',
            'owns': [],
            'public': [],
            'allows': ['missing'],
          },
        ],
      });
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.code, 'UNKNOWN_NODE_ID');
      expect(result.diagnostics.single.rulePointer, '/nodes/0/allows/0');
    },
  );
  test('duplicate IDs fail independently within each namespace', () async {
    for (final kind in ['projects', 'nodes']) {
      final item = kind == 'projects'
          ? {
              'id': 'app',
              'adapter': 'dart',
              'package_roots': ['./'],
            }
          : {
              'id': 'app',
              'responsibility': 'App',
              'owns': [],
              'public': [],
              'allows': [],
            };
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': [],
        'exclude': [],
        'nodes': [],
        kind: [item, item],
      });
      expect(result.status, 'invalid_policy');
      expect(
        result.diagnostics.single.code,
        kind == 'nodes' ? 'DUPLICATE_NODE_ID' : 'DUPLICATE_PROJECT_ID',
      );
      expect(result.diagnostics.single.rulePointer, '/$kind/1/id');
    }
  });
  test(
    'missing local contracts warn while remote references remain metadata',
    () async {
      final requests = <Uri>[];
      final result = await HttpOverrides.runZoned(
        () => loadPolicy({
          'version': 1,
          'projects': [],
          'scope': [],
          'exclude': [],
          'nodes': [
            {
              'id': 'app',
              'responsibility': 'App',
              'owns': [],
              'public': [],
              'allows': [],
              'contracts': [
                'docs/./missing.md',
                'https://invalid.example/never-fetch',
                'docs/missing.md',
              ],
            },
          ],
        }),
        createHttpClient: (_) => _RecordingHttpClient(requests),
      );
      expect(result.status, 'ok');
      expect(result.plan!.node('app')!['contracts'], [
        'docs/missing.md',
        'https://invalid.example/never-fetch',
      ]);
      expect(result.diagnostics.single.code, 'CONTRACT_NOT_FOUND');
      expect(result.diagnostics.single.severity, 'warning');
      expect(result.diagnostics.single.rulePointer, '/nodes/0/contracts/0');
      expect(result.diagnostics.single.path, 'docs/missing.md');
      expect(requests, isEmpty, reason: 'Remote contracts remain metadata.');
    },
  );
  test(
    'declared dependency cycles warn without invalidating the plan',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': [],
        'exclude': [],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'App',
            'owns': [],
            'public': [],
            'allows': ['core'],
          },
          {
            'id': 'core',
            'responsibility': 'Core',
            'owns': [],
            'public': [],
            'allows': ['app'],
          },
        ],
      });
      expect(result.status, 'ok');
      expect(result.diagnostics.single.code, 'POLICY_CYCLE');
      expect(result.diagnostics.single.severity, 'warning');
      expect(result.plan!.allows('app', 'core').decision, 'allowed');
    },
  );
  test(
    'unknown mapping keys identify their RFC6901 escaped property',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': [],
        'exclude': [],
        'nodes': [
          {
            'id': 'app',
            'responsibility': 'App',
            'owns': [],
            'public': [],
            'allows': [],
            'extra/~': true,
          },
        ],
      });
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.code, 'POLICY_SCHEMA_INVALID');
      expect(result.diagnostics.single.rulePointer, '/nodes/0/extra~1~0');
    },
  );
  test(
    'normalizes the whole plan before evaluating ownership overlaps',
    () async {
      final result = await loadPolicy({
        'version': 1,
        'projects': [],
        'scope': ['./'],
        'exclude': [],
        'nodes': [
          {
            'id': 'a',
            'responsibility': 'A',
            'owns': ['src/'],
            'public': [],
            'allows': [],
          },
          {
            'id': 'b',
            'responsibility': 'B',
            'owns': ['src/'],
            'public': [],
            'allows': [],
          },
          {
            'id': 'c',
            'responsibility': 'C',
            'owns': ['../escape'],
            'public': [],
            'allows': [],
          },
        ],
      });
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.code, 'POLICY_PATH_INVALID');
      expect(result.diagnostics.single.rulePointer, '/nodes/2/owns/0');
    },
  );
  test('normalized path sets are ordered by Unicode code point', () async {
    final result = await loadPolicy({
      'version': 1,
      'projects': [],
      'scope': ['src/'],
      'exclude': [],
      'nodes': [
        {
          'id': 'app',
          'responsibility': 'App',
          'owns': ['src/'],
          'public': ['src/😀', 'src/\ue000'],
          'allows': [],
        },
      ],
    });
    expect(result.plan!.node('app')!['public'], ['src/\ue000', 'src/😀']);
  });
  test('malformed bytes retain their real hash and return invalid_policy', () async {
    final root = await Directory.systemTemp.createTemp('archway-bad-policy-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/architecture.yaml').writeAsString('[');
    final result = await Plan.load(RepositorySelection(root.path));
    expect(result.status, 'invalid_policy');
    expect(result.plan, isNull);
    expect(
      result.policyHash,
      'sha256:245843abef9e72e7efac30138a994bf6301e7e1d7d7042a33d42e863d2638811',
    );
    expect(result.diagnostics.single.code, 'POLICY_PARSE_ERROR');
  });

  test('missing policy is a read error with no invented hash', () async {
    final root = await Directory.systemTemp.createTemp(
      'archway-missing-policy-',
    );
    addTearDown(() => root.delete(recursive: true));
    final result = await Plan.load(RepositorySelection(root.path));
    expect(result.status, 'error');
    expect(result.policyHash, isNull);
    expect(result.diagnostics.single.code, 'POLICY_READ_FAILED');
  });

  test(
    'empty policy still requires the closed typed versioned root shape',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-shape-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml')
          .writeAsString('projects: []\nscope: []\nexclude: []\nnodes: []\n');
      final result = await Plan.load(RepositorySelection(root.path));
      expect(result.status, 'invalid_policy');
      expect(result.diagnostics.single.code, 'POLICY_SCHEMA_INVALID');
      expect(result.diagnostics.single.rulePointer, '/version');
    },
  );

  test(
    'scope-only empty plan validates without inspecting future source files',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-not-yet-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: [src/]\nexclude: []\nnodes: []\n',
      );
      final result = await Plan.load(RepositorySelection(root.path));
      expect(
        result.status,
        'ok',
        reason: result.diagnostics
            .map((d) => '${d.code}:${d.message}:${d.rulePointer}')
            .join(';'),
      );
      expect(result.plan!.nodeCount, 0);
      expect(result.diagnostics.single.code, 'EMPTY_PLAN');
    },
  );
}

Future<PlanLoad> loadPolicy(Map<String, Object?> policy) async {
  final root = await Directory.systemTemp.createTemp('archway-policy-');
  addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/architecture.yaml')
      .writeAsString(jsonEncode(policy));
  return Plan.load(RepositorySelection(root.path));
}

// Observe requests, not harmless client construction, without opening a socket.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this.requests);

  final List<Uri> requests;

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    requests.add(url);
    return Future.error(StateError('Unexpected contract request: $url'));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
