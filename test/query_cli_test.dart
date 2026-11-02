import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner emits full normalized ownership and negative unmatched transport',
    () async {
      final root = await queryRoot();
      final owned = await invoke(root, ['owner', r'./src\app\new.ts']);
      expect(owned['status'], 'ok');
      expect(owned['exit_code'], 0);
      expect(owned['payload'], {
        'path': 'src/app/new.ts',
        'ownership': 'owned',
        'owner_id': 'app',
      });
      expect(owned['policy_path'], 'architecture.yaml');
      expect(owned['policy_hash'], matches(r'^sha256:[0-9a-f]{64}$'));
      for (final entry in {
        'src/generated/a.ts': 'excluded',
        'outside/a.ts': 'outside_scope',
        'src/unknown.ts': 'unowned',
      }.entries) {
        final value = await invoke(root, ['owner', entry.key]);
        expect(value['status'], 'negative');
        expect(value['exit_code'], 1);
        expect(value['payload'], {
          'path': entry.key,
          'ownership': entry.value,
          'owner_id': null,
        });
      }
    },
  );
  test('node details identify direct neighbors by id and owned path', () async {
    final root = await queryRoot();
    final byId = await invoke(root, ['node', 'core']);
    expect(byId['status'], 'ok');
    expect(byId['payload'], {
      'mode': 'id',
      'node': {
        'id': 'core',
        'responsibility': 'Core',
        'owns': ['src/core/'],
        'public': ['src/core/api'],
        'contracts': [],
        'allows': [],
        'allowed_dependents': [
          {'id': 'app', 'responsibility': 'App'},
        ],
      },
    });
    final byPath = await invoke(root, ['node', '--path=src/core/new']);
    expect(byPath['payload'], {
      'mode': 'path',
      'ownership': {
        'path': 'src/core/new',
        'ownership': 'owned',
        'owner_id': 'core',
      },
      'node': byId['payload']['node'],
    });
    final unmatched = await invoke(root, ['node', '--path', 'src/unowned']);
    expect(unmatched['status'], 'negative');
    expect(unmatched['exit_code'], 1);
    expect(unmatched['payload']['node'], isNull);
    final unknown = await invoke(root, ['node', 'missing']);
    expect(unknown['status'], 'error');
    expect(unknown['exit_code'], 2);
    expect(unknown['payload'], isNull);
    expect(unknown['diagnostics'][0]['code'], 'UNKNOWN_NODE_ID');
    expect(unknown['policy_hash'], isNotNull);
  });

  test(
    'allows distinguishes module permission from file access and uncertainty',
    () async {
      final root = await queryRoot();
      final module = await invoke(root, ['allows', 'app', 'core']);
      expect(module['status'], 'ok');
      expect(module['payload'], {
        'mode': 'ids',
        'policy_only': true,
        'decision_scope': 'module',
        'from_id': 'app',
        'to_id': 'core',
        'policy_decision': 'allowed',
        'reason': 'declared_allow',
      });
      final denied = await invoke(root, ['allows', 'core', 'app']);
      expect(denied['exit_code'], 1);
      expect(denied['payload']['reason'], 'not_allowed');
      final file = await invoke(root, [
        'allows',
        '--paths',
        'src/app/new',
        'src/core/api',
      ]);
      expect(file['status'], 'ok');
      expect(file['payload'], {
        'mode': 'paths',
        'policy_only': true,
        'decision_scope': 'file',
        'from': {
          'path': 'src/app/new',
          'ownership': 'owned',
          'owner_id': 'app',
        },
        'to': {
          'path': 'src/core/api',
          'ownership': 'owned',
          'owner_id': 'core',
        },
        'policy_decision': 'allowed',
        'reason': 'declared_allow',
      });
      final private = await invoke(root, [
        'allows',
        '--paths',
        'src/app/new',
        'src/core/private',
      ]);
      expect(private['exit_code'], 1);
      expect(private['payload']['reason'], 'target_not_public');
      final undetermined = await invoke(root, [
        'allows',
        '--paths',
        'src/missing',
        'src/core/api',
      ]);
      expect(undetermined['status'], 'negative');
      expect(undetermined['payload']['policy_decision'], 'undetermined');
      expect(undetermined['payload']['reason'], 'ownership_unknown');
      final unknown = await invoke(root, ['allows', 'missing', 'core']);
      expect(unknown['status'], 'error');
      expect(unknown['payload'], isNull);
      expect(unknown['diagnostics'][0]['code'], 'UNKNOWN_NODE_ID');
    },
  );

  test('implemented query help describes its actual grammar', () async {
    for (final entry in {
      'owner': 'PATH',
      'node': '--path PATH',
      'allows': '--paths FROM TO',
    }.entries) {
      final out = StringBuffer();
      expect(
        await CLI().run([entry.key, '--help'], CliStreams(out, StringBuffer())),
        0,
      );
      expect(out.toString(), contains(entry.value));
      expect(out.toString(), isNot(contains('not implemented')));
    }
  });

  test(
    'paths mode requires two following operands before any policy read',
    () async {
      final root = await queryRoot();
      await File('${root.path}/architecture.yaml').delete();
      final value = await invoke(root, [
        'allows',
        'src/app/a',
        'src/core/api',
        '--paths',
      ]);
      expect(value['status'], 'usage_error');
      expect(value['exit_code'], 64);
      expect(value['policy_hash'], isNull);
    },
  );
  test('query warnings retain original pointers and code-point diagnostic ordering', () async {
    final root = await queryRoot();
    final file = File('${root.path}/architecture.yaml');
    final policy = jsonDecode(await file.readAsString());
    policy['nodes'][0]['contracts'] = ['docs/😀', 'docs/\ue000'];
    await file.writeAsString(jsonEncode(policy));
    final value = await invoke(root, ['owner', 'src/app/a']);
    expect(value['status'], 'ok');
    expect(value['diagnostics'].map((d) => d['path']).toList(), [
      'docs/\ue000',
      'docs/😀',
    ]);
    expect(value['diagnostics'].map((d) => d['rule_pointer']).toList(), [
      '/nodes/0/contracts/1',
      '/nodes/0/contracts/0',
    ]);
    for (final d in value['diagnostics']) {
      expect(d['severity'], 'warning');
      expect(d['source_range'], isNull);
      expect(d['project_id'], isNull);
      expect(d['recovery_hints'], isEmpty);
    }
  });
}

Future<Directory> queryRoot() async {
  final root = await Directory.systemTemp.createTemp('archway-query-');
  addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/architecture.yaml').writeAsString(
    jsonEncode({
      'version': 1,
      'projects': [],
      'scope': ['src/'],
      'exclude': ['src/generated/'],
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
          'allows': [],
        },
      ],
    }),
  );
  return root;
}

Future<Map<String, dynamic>> invoke(Directory root, List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final exit = await CLI().run([
    '--root',
    root.path,
    ...args,
  ], CliStreams(out, err));
  expect(err.toString(), '');
  expect(out.toString().split('\n'), hasLength(2));
  final value = jsonDecode(out.toString()) as Map<String, dynamic>;
  expect(value['exit_code'], exit);
  return value;
}
