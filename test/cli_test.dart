import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'CLI init emits one complete JSON result and creates its two files',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-cli-');
      addTearDown(() => root.delete(recursive: true));
      final out = StringBuffer();
      final err = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'init',
        '--template',
        'mixed',
      ], CliStreams(out, err));
      expect(exit, 0);
      expect(err.toString(), '');
      expect(out.toString().split('\n'), hasLength(2));
      final value = jsonDecode(out.toString()) as Map;
      expect(value.keys.toSet(), {
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
      expect(value['command'], 'init');
      expect(value['schema_version'], 1);
      expect(value['resolved_root'], await root.resolveSymbolicLinks());
      expect(value['policy_path'], isNull);
      expect(value['policy_hash'], isNull);
      expect(value['status'], 'ok');
      expect(value['exit_code'], exit);
      expect(value['diagnostics'], isEmpty);
      expect(value['tool_versions'], {
        'archway': '0.1.0',
        'dart_adapter': null,
        'typescript_adapter': null,
        'dart_sdk': null,
        'node': null,
        'typescript': null,
      });
      expect(value['payload'], {
        'template': 'mixed',
        'dry_run': false,
        'outcome': 'created',
        'planned_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
        'planned_files': [],
        'created_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
        'residual_paths': [],
        'conflicting_paths': [],
      });
      expect(await root.list().length, 2);
    },
  );
  test('CLI validates the exact init result with counts, hash and warning', () async {
    final root = await Directory.systemTemp.createTemp('archway-cli-validate-');
    addTearDown(() => root.delete(recursive: true));
    await CLI().run([
      '--root',
      root.path,
      'init',
      '--template',
      'dart',
    ], CliStreams(StringBuffer(), StringBuffer()));
    final out = StringBuffer();
    final err = StringBuffer();
    final exit = await CLI().run([
      'validate',
      '--root',
      root.path,
    ], CliStreams(out, err));
    final value = jsonDecode(out.toString()) as Map;
    expect(exit, 0);
    expect(err.toString(), '');
    expect(value['command'], 'validate');
    expect(value['status'], 'ok');
    expect(value['policy_path'], 'architecture.yaml');
    expect(
      value['policy_hash'],
      'sha256:1fa6dfc3610e9591b0e1c8dfd3d4690d548e0f23f55ff12c2b5c0fb8189f9a48',
    );
    expect(value['payload'], {'policy_valid': true, 'projects': 0, 'nodes': 0});
    expect(value['diagnostics'], [
      {
        'code': 'EMPTY_PLAN',
        'severity': 'warning',
        'message': 'The policy has no projects or nodes.',
        'rule_pointer': null,
        'source_range': null,
        'project_id': null,
        'path': null,
        'recovery_hints': [],
      },
    ]);
  });

  test('init --policy is a usage error before any filesystem writes', () async {
    final root = await Directory.systemTemp.createTemp('archway-cli-usage-');
    addTearDown(() => root.delete(recursive: true));
    final out = StringBuffer();
    final exit = await CLI().run([
      'init',
      '--root',
      root.path,
      '--template',
      'mixed',
      '--policy',
      'other.yaml',
    ], CliStreams(out, StringBuffer()));
    final value = jsonDecode(out.toString()) as Map;
    expect(exit, 64);
    expect(value['status'], 'usage_error');
    expect(value['command'], 'init');
    expect(value['payload'], isNull);
    expect(value['policy_path'], isNull);
    expect(value['policy_hash'], isNull);
    expect((value['diagnostics'] as List).single['code'], 'USAGE_ERROR');
    expect(await root.list().toList(), isEmpty);
  });

  test('unsupported repeated missing and incompatible arguments fail before writes', () async {
    final root = await Directory.systemTemp.createTemp('archway-cli-grammar-');
    addTearDown(() => root.delete(recursive: true));
    final cases = <List<String>>[
      [],
      ['unknown'],
      ['init'],
      ['init', '--template'],
      ['init', '--template', 'rust'],
      ['init', '--template', 'dart', 'extra'],
      ['init', '--template', 'dart', '--force'],
      ['init', '--template', 'dart', '--template', 'mixed'],
      ['init', '--template', 'dart', '--dry-run=false'],
      ['validate', '--json'],
      ['validate', 'extra'],
      ['validate', '--policy', 'a', '--policy', 'b'],
      ['validate', '--root', root.path],
      ['check', '--json'],
      ['owner'],
    ];
    for (final args in cases) {
      final out = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        ...args,
      ], CliStreams(out, StringBuffer()));
      expect(exit, 64, reason: args.toString());
      final result = jsonDecode(out.toString()) as Map;
      expect(result['status'], 'usage_error');
      expect(result['payload'], isNull);
      expect(
        result['command'],
        args.isEmpty || args.first == 'unknown' ? null : args.first,
      );
      expect(await root.list().toList(), isEmpty);
    }
  });

  test('missing or nondirectory selected roots are usage errors with complete JSON', () async {
    final temp = await Directory.systemTemp.createTemp('archway-root-');
    addTearDown(() => temp.delete(recursive: true));
    await File('${temp.path}/file').writeAsString('not root');
    for (final root in [
      '${temp.path}/missing',
      '${temp.path}/file',
      '${temp.path}/missing-parent/child',
      '${temp.path}/file/child',
    ]) {
      // Real filesystem fixtures: a load/setup failure cannot establish the
      // contractual result for an inaccessible selected root.
      print('ROOT_CLASSIFICATION_FIXTURE_READY: $root');
      final out = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root,
        'validate',
      ], CliStreams(out, StringBuffer()));
      final value = jsonDecode(out.toString()) as Map;
      expect(exit, 64, reason: '$root: ${out.toString()}');
      expect(value['exit_code'], 64, reason: root);
      expect(value['status'], 'usage_error', reason: root);
      expect(value['command'], 'validate', reason: root);
      expect(value['resolved_root'], isNull, reason: root);
      expect(value['payload'], isNull, reason: root);
    }
  });

  test(
    'CLI dry-run conflict returns complete planned contents and error exit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'archway-cli-conflict-',
      );
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString('keep');
      final out = StringBuffer();
      final err = StringBuffer();
      final exit = await CLI().run([
        'init',
        '--template=mixed',
        '--root=${root.path}',
        '--dry-run',
      ], CliStreams(out, err));
      final value = jsonDecode(out.toString()) as Map;
      expect(exit, 2);
      expect(value['status'], 'error');
      expect(value['payload']['outcome'], 'conflict');
      expect(value['payload']['planned_files'], hasLength(2));
      expect(value['payload']['created_paths'], isEmpty);
      expect(value['payload']['conflicting_paths'], ['architecture.yaml']);
      expect(value['diagnostics'][0]['code'], 'INIT_TARGET_EXISTS');
      expect(value['diagnostics'][0]['recovery_hints'], isNotEmpty);
      expect(err.toString(), '');
      expect(
        await File('${root.path}/architecture.yaml').readAsString(),
        'keep',
      );
    },
  );

  test('standalone help version and command help are text-only without policy access', () async {
    for (final args in [
      ['--help'],
      ['--version'],
      ['init', '--help'],
      ['validate', '--help'],
    ]) {
      final out = StringBuffer();
      final err = StringBuffer();
      final exit = await CLI().run(args, CliStreams(out, err));
      expect(exit, 0, reason: args.toString());
      expect(out.toString(), startsWith('archway'));
      expect(out.toString(), endsWith('\n'));
      expect(err.toString(), '');
    }
  });

  test('export help describes output without platform restrictions', () async {
    final out = StringBuffer();
    final err = StringBuffer();
    final exit = await CLI().run(['export', '--help'], CliStreams(out, err));

    expect(exit, 0);
    expect(
      out.toString(),
      'archway [--root ROOT] export [--policy PATH] --format mermaid '
      '[--out PATH [--overwrite]]\n'
      'Exports the complete declared graph. Mermaid goes to stdout or the file; '
      'JSON diagnostics go to stderr.\n',
    );
    expect(err.toString(), '');
  });

  test(
    'selected policy is normalized inside exactly the selected root',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'archway-selection-',
      );
      addTearDown(() => parent.delete(recursive: true));
      final root = await Directory('${parent.path}/child').create();
      await File('${parent.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final missingOut = StringBuffer();
      expect(
        await CLI().run([
          'validate',
          '--root',
          root.path,
        ], CliStreams(missingOut, StringBuffer())),
        2,
      );
      expect(
        jsonDecode(missingOut.toString())['diagnostics'][0]['code'],
        'POLICY_READ_FAILED',
      );
      await File('${root.path}/chosen.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final out = StringBuffer();
      final exit = await CLI().run([
        '--root',
        root.path,
        'validate',
        '--policy=./unused/../chosen.yaml',
      ], CliStreams(out, StringBuffer()));
      expect(exit, 0);
      expect(jsonDecode(out.toString())['policy_path'], 'chosen.yaml');
    },
  );

  test(
    'invalid root and policy syntax fails before repository access',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'archway-invalid-selection-',
      );
      addTearDown(() => root.delete(recursive: true));
      for (final policy in [
        '/tmp/policy.yaml',
        'http:policy',
        'bad<name',
        'bad>name',
        'bad|name',
        'bad"name',
        'CON',
        'aux.yaml',
        'a/LPT9.txt',
        'trailing.',
        'trailing ',
        '../policy.yaml',
        'a/../../policy.yaml',
        'C:\\policy.yaml',
        'x*',
        'x?',
        'a[0]',
        'a{b}',
        'dir/',
        'dir/.',
        '.',
        'a\u0000b',
      ]) {
        final out = StringBuffer();
        final exit = await CLI().run([
          'validate',
          '--root',
          root.path,
          '--policy',
          policy,
        ], CliStreams(out, StringBuffer()));
        expect(exit, 64, reason: policy);
        expect(jsonDecode(out.toString())['payload'], isNull);
      }
      final out = StringBuffer();
      expect(
        await CLI().run([
          'validate',
          '--root',
          'bad\u0000root',
        ], CliStreams(out, StringBuffer())),
        64,
      );
    },
  );

  test(
    'policy paths normalize Unicode NFC and separators while preserving case',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-unicode-');
      addTearDown(() => root.delete(recursive: true));
      await Directory('${root.path}/café').create();
      await File('${root.path}/café/Policy.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final out = StringBuffer();
      final exit = await CLI().run([
        'validate',
        '--root',
        root.path,
        '--policy',
        'cafe\u0301\\Policy.yaml',
      ], CliStreams(out, StringBuffer()));
      expect(exit, 0);
      expect(jsonDecode(out.toString())['policy_path'], 'café/Policy.yaml');
    },
  );

  test('preparation failure produces null init payload with complete error transport', () async {
    final root = await Directory.systemTemp.createTemp('archway-cli-prepare-');
    addTearDown(() => root.delete(recursive: true));
    final out = StringBuffer();
    final exit = await runZoned(
      () => CLI().run([
        'init',
        '--root',
        root.path,
        '--template',
        'dart',
      ], CliStreams(out, StringBuffer())),
      zoneValues: {
        #archwayBootstrapFault: (String stage, String path) {
          if (stage == 'beforePrepare')
            throw FileSystemException(
              'Root access denied',
              path,
              const OSError('denied', 13),
            );
        },
      },
    );
    final value = jsonDecode(out.toString()) as Map;
    expect(exit, 2);
    expect(value['status'], 'error');
    expect(value['payload'], isNull);
    expect(value['policy_path'], isNull);
    expect(value['policy_hash'], isNull);
    expect(value['diagnostics'], isNotEmpty);
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'diagnostics sort by path while init outcomes keep the fixed target order',
    () async {
      final root = await Directory.systemTemp.createTemp('archway-cli-sort-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/architecture.yaml').writeAsString('policy');
      await File('${root.path}/ARCHITECTURE.md').writeAsString('guide');
      final out = StringBuffer();
      expect(
        await CLI().run([
          'init',
          '--root',
          root.path,
          '--template',
          'dart',
        ], CliStreams(out, StringBuffer())),
        2,
      );
      final value = jsonDecode(out.toString());
      expect((value['diagnostics'] as List).map((d) => d['path']), [
        'ARCHITECTURE.md',
        'architecture.yaml',
      ]);
      expect(value['payload']['conflicting_paths'], [
        'architecture.yaml',
        'ARCHITECTURE.md',
      ]);
    },
  );

  test('export missing format retains its separate error transport', () async {
    final out = StringBuffer();
    final err = StringBuffer();
    final exit = await CLI().run(['export'], CliStreams(out, err));
    expect(exit, 64);
    expect(out.toString(), '');
    final value = jsonDecode(err.toString());
    expect(value['command'], 'export');
    expect(value['status'], 'usage_error');
    expect(value['payload'], {'format': null, 'out': null});
    expect(value['diagnostics'][0]['message'], contains('--format mermaid'));
  });

  test(
    'CLI retains full first and second write-failure outcomes and exit streams',
    () async {
      for (final target in ['architecture.yaml', 'ARCHITECTURE.md']) {
        final root = await Directory.systemTemp.createTemp(
          'archway-cli-write-fail-',
        );
        addTearDown(() => root.delete(recursive: true));
        final out = StringBuffer();
        final err = StringBuffer();
        final exit = await runZoned(
          () => CLI().run([
            'init',
            '--root',
            root.path,
            '--template',
            'mixed',
          ], CliStreams(out, err)),
          zoneValues: {
            #archwayBootstrapFault: (String stage, String path) {
              if (stage == 'beforeWrite' && path == target)
                throw FileSystemException('Injected write failure', path);
            },
          },
        );
        final value = jsonDecode(out.toString());
        final expected = target == 'architecture.yaml'
            ? ['architecture.yaml']
            : ['architecture.yaml', 'ARCHITECTURE.md'];
        expect(exit, 2);
        expect(value['exit_code'], exit);
        expect(value['status'], 'error');
        expect(value['payload']['outcome'], 'partial');
        expect(value['payload']['created_paths'], expected);
        expect(value['payload']['residual_paths'], expected);
        expect(value['payload']['planned_files'], isEmpty);
        expect(value['policy_hash'], isNull);
        expect(
          (value['diagnostics'] as List).map((d) => d['code']),
          containsAll(['INIT_WRITE_FAILED', 'INIT_ROLLBACK_FAILED']),
        );
        expect(err.toString(), '');
        expect(out.toString().split('\n'), hasLength(2));
      }
    },
  );
  test(
    'global argument failures still identify the operational command',
    () async {
      for (final args in [
        ['--root', '--bad', 'init', '--template', 'dart'],
        ['--template', 'dart', 'init'],
        ['--unknown', 'validate'],
      ]) {
        final out = StringBuffer();
        expect(await CLI().run(args, CliStreams(out, StringBuffer())), 64);
        final value = jsonDecode(out.toString());
        expect(value['command'], args.contains('init') ? 'init' : 'validate');
        expect(value['payload'], isNull);
      }
    },
  );
}
