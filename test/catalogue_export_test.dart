import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'CLI maximum pagination retains exact metadata and JSON transport',
    () async {
      final root = await graphRoot();
      const maximum = 9223372036854775807;
      for (final (offset, payload) in [
        (
          1,
          {
            'mode': 'catalogue',
            'nodes': [
              {'id': 'core', 'responsibility': 'Core', 'owns_count': 1},
              {'id': 'leaf', 'responsibility': 'Leaf', 'owns_count': 0},
            ],
            'total': 3,
            'omitted': 1,
            'offset': 1,
            'limit': maximum,
          },
        ),
        (
          maximum,
          {
            'mode': 'catalogue',
            'nodes': [],
            'total': 3,
            'omitted': 3,
            'offset': maximum,
            'limit': maximum,
          },
        ),
      ]) {
        final result = await run(root, [
          'node',
          '--offset',
          '$offset',
          '--limit',
          '9223372036854775807',
        ]);
        expect(result.$1, 0);
        expect(result.$3, '');
        final value = jsonDecode(result.$2);
        expect(value['payload'], payload, reason: 'offset $offset');
      }
    },
  );
  test(
    'CLI catalogue exposes full and explicitly paginated payloads',
    () async {
      final root = await graphRoot();
      final full = await run(root, ['node']);
      expect(full.$1, 0);
      expect(full.$3, '');
      final value = jsonDecode(full.$2);
      expect(value['policy_hash'], matches(r'^sha256:[0-9a-f]{64}$'));
      expect(value['payload'], {
        'mode': 'catalogue',
        'nodes': [
          {'id': 'app', 'responsibility': 'App', 'owns_count': 1},
          {'id': 'core', 'responsibility': 'Core', 'owns_count': 1},
          {'id': 'leaf', 'responsibility': 'Leaf', 'owns_count': 0},
        ],
        'total': 3,
        'omitted': 0,
        'offset': 0,
        'limit': null,
      });
      final page = await run(root, ['node', '--limit=1', '--offset', '1']);
      expect(page.$1, 0);
      expect(jsonDecode(page.$2)['payload'], {
        'mode': 'catalogue',
        'nodes': [
          {'id': 'core', 'responsibility': 'Core', 'owns_count': 1},
        ],
        'total': 3,
        'omitted': 2,
        'offset': 1,
        'limit': 1,
      });
      final beyond = await run(root, ['node', '--offset', '99']);
      expect(beyond.$1, 0);
      expect(beyond.$3, '');
      expect(jsonDecode(beyond.$2)['payload'], {
        'mode': 'catalogue',
        'nodes': [],
        'total': 3,
        'omitted': 3,
        'offset': 99,
        'limit': null,
      });
    },
  );
  test(
    'export is deterministic pure declared Mermaid with no runtime',
    () async {
      final root = await graphRoot();
      final hash = (await Plan.load(RepositorySelection(root.path))).policyHash;
      final result = await run(root, ['export', '--format=mermaid']);
      expect(result.$1, 0);
      expect(result.$3, '');
      expect(
        result.$2,
        '%% Declared policy permissions\n'
        '%% Policy hash: $hash\n'
        'flowchart LR\n'
        '  n0["app: App"]\n'
        '  n1["core: Core"]\n'
        '  n2["leaf: Leaf"]\n'
        '  n0 --> n1\n'
        '  n1 --> n2\n',
      );
      expect(await run(root, ['export', '--format', 'mermaid']), result);
    },
  );
  test(
    'export escapes user labels and renders cycle warnings separately',
    () async {
      for (final (responsibility, body) in [
        (
          'App',
          'flowchart LR\n'
              '  n0["app: App"]\n'
              '  n1["core: Core"]\n'
              '  n2["leaf: Leaf"]\n'
              '  n0 --> n1\n'
              '  n1 --> n2\n'
              '  n2 --> n0\n',
        ),
        (
          '"<>[]&;#\n%%{x} café 😀',
          'flowchart LR\n'
              '  n0["app: #34;#60;#62;#91;#93;#38;#59;#35;#10;#37;#37;#123;x#125; caf#233; #128512;"]\n'
              '  n1["core: Core"]\n'
              '  n2["leaf: Leaf"]\n'
              '  n0 --> n1\n'
              '  n1 --> n2\n'
              '  n2 --> n0\n',
        ),
      ]) {
        final root = await graphRoot();
        final file = File('${root.path}/architecture.yaml');
        final policy = jsonDecode(await file.readAsString());
        policy['nodes'][0]['allows'] = ['app'];
        policy['nodes'][2]['responsibility'] = responsibility;
        await file.writeAsString(jsonEncode(policy));
        final result = await run(root, ['export', '--format', 'mermaid']);
        expect(result.$1, 0);
        expect(
          result.$2.split('\n').skip(2).join('\n'),
          body,
          reason: responsibility,
        );
        final diagnostics = jsonDecode(result.$3);
        expect(diagnostics['command'], 'export');
        expect(diagnostics['status'], 'ok');
        expect(diagnostics['exit_code'], 0);
        expect(diagnostics['payload'], {'format': 'mermaid', 'out': null});
        expect(diagnostics['diagnostics'].map((d) => d['code']).toList(), [
          'POLICY_CYCLE',
        ]);
        expect(result.$3.split('\n'), hasLength(2));
      }
    },
  );
  test('export usage retains recognized format and normalized output without writes', () async {
    final root = await graphRoot();
    final result = await run(root, [
      'export',
      '--format',
      'mermaid',
      '--out',
      './graph.mmd',
      '--bogus',
    ]);
    expect(result.$1, 64);
    expect(result.$2, '');
    final value = jsonDecode(result.$3);
    expect(value['payload'], {'format': 'mermaid', 'out': 'graph.mmd'});
    expect(value['policy_hash'], isNull);
    expect(value['diagnostics'][0]['code'], 'USAGE_ERROR');
    expect(await File('${root.path}/graph.mmd').exists(), false);
  });
  test(
    'file export exclusively creates output and requires explicit overwrite',
    () async {
      final runnerTemp = Platform.environment['RUNNER_TEMP'];
      final temporary = await graphRoot(
        base: Platform.isWindows && runnerTemp != null
            ? Directory(runnerTemp)
            : null,
      );
      final root = Directory(await temporary.resolveSymbolicLinks());
      print('OVERWRITE_TEST_ROOT=${root.path}');
      final expected = (await run(root, ['export', '--format', 'mermaid'])).$2;
      final args = ['export', '--format', 'mermaid', '--out', './graph.mmd'];
      expect(await run(root, args), (0, '', ''));
      final file = File('${root.path}/graph.mmd');
      expect(await file.readAsString(), expected);
      await file.writeAsString('keep this');
      final conflict = await run(root, args);
      expect(conflict.$1, 2);
      expect(conflict.$2, '');
      expect(
        jsonDecode(conflict.$3)['diagnostics'][0]['code'],
        'EXPORT_TARGET_EXISTS',
        reason: conflict.$3,
      );
      expect(jsonDecode(conflict.$3)['payload'], {
        'format': 'mermaid',
        'out': 'graph.mmd',
      });
      expect(await file.readAsString(), 'keep this');
      expect(await run(root, [...args, '--overwrite']), (0, '', ''));
      expect(await file.readAsString(), expected);
    },
  );
  test('file export exclusively creates output through existing child directories', () async {
    final runnerTemp = Platform.environment['RUNNER_TEMP'];
    final temporary = await graphRoot(
      base: Platform.isWindows && runnerTemp != null
          ? Directory(runnerTemp)
          : null,
    );
    // Isolate directory traversal from aliases such as macOS /var -> /private.
    final root = Directory(await temporary.resolveSymbolicLinks());
    print('NESTED_EXPORT_TEST_ROOT=${root.path}');
    final directory = await Directory('${root.path}/nested/deeper')
        .create(recursive: true);
    final stdoutExport = await run(root, ['export', '--format', 'mermaid']);
    expect(stdoutExport.$1, 0, reason: stdoutExport.$3);
    expect(stdoutExport.$3, '');
    final result = await run(root, [
      'export',
      '--format',
      'mermaid',
      '--out',
      'nested/deeper/graph.mmd',
    ]);
    expect(result, (0, '', ''), reason: result.$3);
    expect(
      await File('${directory.path}/graph.mmd').readAsString(),
      stdoutExport.$2,
    );
    expect(await File('${root.path}/graph.mmd').exists(), false);
  });
  test(
    'ordinary overwrite preserves existing hardlink path semantics',
    () async {
      final root = await graphRoot();
      final expected = (await run(root, ['export', '--format', 'mermaid'])).$2;
      final original = File('${root.path}/original.mmd');
      await original.writeAsString('old');
      final destination = File('${root.path}/graph.mmd').absolute.path;
      final systemRoot = Platform.environment['SystemRoot'];
      if (Platform.isWindows) expect(systemRoot, isNotNull);
      final linked = Platform.isWindows
          ? await Process.run('$systemRoot/System32/fsutil.exe',
              ['hardlink', 'create', destination, original.absolute.path])
          : await Process.run('ln', [original.path, destination]);
      expect(linked.exitCode, 0, reason: linked.stderr.toString());
      expect(
        await run(root, [
          'export',
          '--format',
          'mermaid',
          '--out',
          'graph.mmd',
          '--overwrite',
        ]),
        (0, '', ''),
      );
      expect(await original.readAsString(), expected);
      expect(await File('${root.path}/graph.mmd').readAsString(), expected);
    },
  );
  for (final observeWrittenBytes in [false, true]) {
    test(
      observeWrittenBytes
          ? 'live FIFO reader observes bytes written after readiness'
          : 'overwrite rejects a FIFO with a live reader before sending content',
      () async {
        final root = await graphRoot();
        final fifo = '${root.path}/pipe.mmd';
        final reader = await Process.start(Platform.resolvedExecutable, [
          'test/support/posix_fifo_reader_child.dart',
          fifo,
        ]);
        var exited = false;
        final completion = reader.exitCode.then((code) {
          exited = true;
          return code;
        });
        final errors = <int>[];
        final errorSubscription = reader.stderr.listen(errors.addAll);
        final lines = StreamIterator(
          reader.stdout.transform(utf8.decoder).transform(const LineSplitter()),
        );
        addTearDown(() async {
          try {
            if (!exited) {
              reader.kill(ProcessSignal.sigkill);
              await completion.timeout(const Duration(seconds: 5));
            }
          } finally {
            await Future.wait([
              lines.cancel(),
              errorSubscription.cancel(),
              reader.stdin.close(),
            ]).timeout(const Duration(seconds: 5));
          }
        });
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 5)),
          true,
        );
        expect(lines.current, 'ready');
        final result = await run(root, [
          'export',
          '--format',
          'mermaid',
          '--out',
          'pipe.mmd',
          '--overwrite',
        ]);
        if (observeWrittenBytes) {
          await File(fifo)
              .writeAsBytes([1, 2, 3, 4, 5])
              .timeout(const Duration(seconds: 5));
        }
        reader.stdin.writeln('inspect');
        await reader.stdin.flush().timeout(const Duration(seconds: 5));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 5)),
          true,
        );
        expect(
          lines.current,
          observeWrittenBytes ? '5' : '0',
          reason: observeWrittenBytes
              ? 'The reader must observe real bytes, not a fabricated zero'
              : 'Unsupported outputs must receive no export bytes',
        );
        expect(result.$1, 2);
        expect(result.$2, '');
        expect(
          jsonDecode(result.$3)['diagnostics'][0]['code'],
          'EXPORT_WRITE_FAILED',
        );
        expect(
          await completion.timeout(const Duration(seconds: 5)),
          0,
          reason: utf8.decode(errors, allowMalformed: true),
        );
      },
      skip: Platform.isWindows
          ? 'POSIX FIFO entries are unavailable on Windows; Win32 sharing faults have separate process coverage.'
          : false,
    );
  }
  test(
    'export refuses intermediate child symlinks for create and overwrite',
    () async {
      final root = await graphRoot();
      final outside = await Directory.systemTemp.createTemp('archway-outside-');
      addTearDown(() => outside.delete(recursive: true));
      await Link('${root.path}/escape').create(outside.path);
      final existing = File('${outside.path}/existing.mmd');
      await existing.writeAsString('outside work');
      for (final target in ['new.mmd', 'existing.mmd']) {
        final result = await run(root, [
          'export',
          '--format',
          'mermaid',
          '--out',
          'escape/$target',
          if (target == 'existing.mmd') '--overwrite',
        ]);
        expect(result.$1, 2);
        expect(result.$2, '');
        expect(
          jsonDecode(result.$3)['diagnostics'][0]['code'],
          'EXPORT_WRITE_FAILED',
        );
      }
      expect(await File('${outside.path}/new.mmd').exists(), false);
      expect(await existing.readAsString(), 'outside work');
    },
  );
  test(
    'catalogue and export reject incompatible grammar before policy I/O',
    () async {
      final root = await graphRoot();
      await File('${root.path}/architecture.yaml').delete();
      for (final args in <List<String>>[
        ['export', '--format', 'mermaid', '--overwrite'],
        ['export'],
        ['export', '--format', 'json'],
        ['export', '--format', 'mermaid', '--out', '../escape'],
        ['export', '--format', 'mermaid', '--out', 'dir/'],
        ['export', '--format', 'mermaid', '--out', 'a/..'],
        ['export', '--format', 'mermaid', '--out', '/tmp/out'],
        [
          'export',
          '--format',
          'mermaid',
          '--out',
          'graph.mmd',
          '--overwrite=true',
        ],
        ['export', '--format', 'mermaid', '--format', 'mermaid'],
        ['export', '--format', 'mermaid', 'extra'],
        ['export', '--format', 'mermaid', '--json'],
        ['export', '--format', 'mermaid', '--limit', '1'],
        ['node', '--limit', '0'],
        ['node', '--offset', '-1'],
        ['node', '--limit', '1.0'],
        ['node', '--offset', '+1'],
        ['node', '--limit', '999999999999999999999999'],
        ['node', 'app', '--limit', '1'],
        ['node', '--path', 'src/app/a', '--offset', '0'],
        ['node', '--limit', '1', '--limit', '2'],
        ['node', '--limit='],
        ['node', 'app', 'core'],
        ['node', '--overwrite'],
        ['node', '--format', 'mermaid'],
        ['node', '--out', 'graph.mmd'],
      ]) {
        final result = await run(root, args);
        expect(result.$1, 64, reason: args.toString());
        final export = args.first == 'export';
        expect(export ? result.$2 : result.$3, '');
        final value = jsonDecode(export ? result.$3 : result.$2);
        expect(value['status'], 'usage_error');
        expect(value['policy_hash'], isNull);
        expect(value['diagnostics'][0]['code'], 'USAGE_ERROR');
        if (args.length == 1 && args.single == 'export') {
          expect(value['command'], 'export');
          expect(value['payload'], {'format': null, 'out': null});
          expect(
            value['diagnostics'][0]['message'],
            contains('--format mermaid'),
          );
        }
      }
    },
  );
  test(
    'offline help documents catalogue and export grammar and streams',
    () async {
      final nodeOut = StringBuffer();
      final nodeExit = await CLI().run([
        'node',
        '--help',
      ], CliStreams(nodeOut, StringBuffer()));
      final node = (nodeExit, nodeOut.toString());
      expect(node.$1, 0);
      expect(node.$2, contains('[--limit N] [--offset N]'));
      expect(node.$2, isNot(contains('deferred')));
      final exportOut = StringBuffer();
      final exportErr = StringBuffer();
      final exportExit = await CLI().run([
        'export',
        '--help',
      ], CliStreams(exportOut, exportErr));
      final export = (exportExit, exportOut.toString());
      expect(export.$1, 0);
      expect(
        export.$2,
        'archway [--root ROOT] export [--policy PATH] --format mermaid '
        '[--out PATH [--overwrite]]\n'
        'Exports the complete declared graph. Mermaid goes to stdout or the file; '
        'JSON diagnostics go to stderr.\n',
      );
      expect(exportErr.toString(), '');
      final out = StringBuffer();
      expect(await CLI().run(['--help'], CliStreams(out, StringBuffer())), 0);
      expect(out.toString(), contains('Mermaid'));
      expect(out.toString(), isNot(contains('export are deferred')));
    },
  );
}

Future<Directory> graphRoot({Directory? base}) async {
  final root = await (base ?? Directory.systemTemp).createTemp(
    'archway-export-',
  );
  addTearDown(() => root.delete(recursive: true));
  await File('${root.path}/architecture.yaml').writeAsString(
    jsonEncode({
      'version': 1,
      'projects': [],
      'scope': ['src/'],
      'exclude': [],
      'nodes': [
        {
          'id': 'leaf',
          'responsibility': 'Leaf',
          'owns': [],
          'public': [],
          'allows': [],
        },
        {
          'id': 'core',
          'responsibility': 'Core',
          'owns': ['src/core/'],
          'public': [],
          'allows': ['leaf'],
        },
        {
          'id': 'app',
          'responsibility': 'App',
          'owns': ['src/app/', 'src/app/'],
          'public': [],
          'allows': ['core', 'core', 'app'],
        },
      ],
    }),
  );
  return root;
}

Future<(int, String, String)> run(Directory root, List<String> args) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final exit = await CLI().run([
    '--root',
    root.path,
    ...args,
  ], CliStreams(out, err));
  return (exit, out.toString(), err.toString());
}
