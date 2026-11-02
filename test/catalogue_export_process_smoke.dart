// Installed catalogue/export framing, safety, pagination and native I/O faults.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/native_file_fixtures.dart';

typedef _Captured = ({int code, List<int> out, List<int> err});

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run test/catalogue_export_process_smoke.dart <executable>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(arguments.single).resolveSymbolicLinksSync();
  final contracts = Directory.fromUri(
    Platform.script.resolve('../contracts/json/'),
  );
  ContractSchema schema(String name) => ContractSchema(
    jsonDecode(
      File(p.join(contracts.path, '$name.schema.json')).readAsStringSync(),
    ),
  );
  final public = schema('public-result'), export = schema('export-diagnostics');
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-export-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final root = Directory(p.join(base.path, 'root café'))..createSync();
    final cwd = Directory(p.join(base.path, 'other cwd'))..createSync();
    File at(String name) => File(p.join(root.path, name));
    final policy = at('architecture.yaml');
    final environment = {
      ...Platform.environment,
      'PATH': p.join(cwd.path, 'no-runtime-here'),
    };
    Map decoded(List<int> bytes) => jsonDecode(utf8.decode(bytes)) as Map;
    void validate(ContractSchema schema, List<int> bytes) {
      final errors = schema.errors(decoded(bytes));
      _check(errors.isEmpty, 'Invalid schema: $errors');
    }

    Future<_Captured> capture(
      String program,
      List<String> args, {
      String? directory,
      Map<String, String>? env,
      Duration? timeout = const Duration(seconds: 10),
    }) async {
      final child = await Process.start(
        program,
        args,
        workingDirectory: directory,
        environment: env ?? Platform.environment,
        includeParentEnvironment: false,
      );
      final out = <int>[], err = <int>[];
      final completion = Future.wait<Object?>([
        child.exitCode,
        child.stdout.forEach(out.addAll),
        child.stderr.forEach(err.addAll),
        child.stdin.close(),
      ]);
      List<Object?> result;
      try {
        result = await (timeout == null
            ? completion
            : completion.timeout(timeout));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await completion.timeout(const Duration(seconds: 2));
        throw TimeoutException('$args timed out; stdout=$out; stderr=$err');
      }
      return (code: result.first as int, out: out, err: err);
    }

    List<String> command(Directory selected, List<String> args) => [
      '--root',
      selected.path,
      ...args,
    ];
    Future<_Captured> invoke(
      List<String> args,
      int expected, {
      bool limitOutput = false,
    }) async {
      final result = await capture(
        limitOutput ? Platform.resolvedExecutable : executable,
        [
          if (limitOutput) ...[
            Platform.script
                .resolve('support/posix_file_limit_child.dart')
                .toFilePath(),
            executable,
          ],
          ...command(root, args),
        ],
        directory: cwd.path,
        env: environment,
      );
      _check(result.code == expected, '$args: $result');
      if (args.first == 'export') {
        if (expected != 0)
          _check(result.out.isEmpty, '$args: unexpected stdout');
        if (result.err.isNotEmpty) {
          _check(
            result.err.where((byte) => byte == 10).length == 1 &&
                result.err.last == 10,
            '$args: expected one export JSON line',
          );
          validate(export, result.err);
          final value = decoded(result.err);
          _check(
            value['exit_code'] == expected,
            '$args: envelope exit mismatch',
          );
          _check(
            value['tool_versions']['node'] == null,
            '$args: unexpected Node runtime',
          );
        }
      } else {
        _check(result.err.isEmpty, '$args: unexpected stderr');
        _check(
          result.out.where((byte) => byte == 10).length == 1 &&
              result.out.last == 10,
          '$args: expected one public JSON line',
        );
        validate(public, result.out);
        _check(
          decoded(result.out)['exit_code'] == expected,
          '$args: envelope exit mismatch',
        );
      }
      count++;
      return result;
    }

    policy.writeAsBytesSync(
      File(p.join(contracts.path, 'fixtures/policy-empty.json'))
          .readAsBytesSync(),
    );
    final empty = await invoke(['export', '--format', 'mermaid'], 0);
    _check(utf8.decode(empty.out).endsWith('flowchart LR\n'), 'Empty diagram');
    _check(
      decoded(empty.err)['diagnostics'][0]['code'] == 'EMPTY_PLAN',
      'Empty-plan warning',
    );
    _check(
      sameJson(decoded((await invoke(['node'], 0)).out)['payload'], {
        'mode': 'catalogue',
        'nodes': [],
        'total': 0,
        'omitted': 0,
        'offset': 0,
        'limit': null,
      }),
      'Empty catalogue',
    );
    String nodeId(int index) => 'n${index.toString().padLeft(4, '0')}';
    final nodes = [
      for (var i = 0; i < 1001; i++)
        {
          'id': nodeId(i),
          'responsibility': 'Node $i',
          'owns': [],
          'public': [],
          'allows': [nodeId((i + 1) % 1001)],
        },
    ];
    policy.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'projects': [],
        'scope': [],
        'exclude': [],
        'nodes': nodes.reversed.toList(),
      }),
    );
    final catalogue = decoded((await invoke(['node'], 0)).out);
    _check(
      catalogue['payload']['nodes'].length == 1001 &&
          catalogue['payload']['omitted'] == 0,
      'Catalogue must retain all 1001 nodes',
    );
    _check(
      catalogue['payload']['nodes'][0]['id'] == 'n0000',
      'First sorted node',
    );
    _check(
      catalogue['payload']['nodes'].last['id'] == 'n1000',
      'Last sorted node',
    );
    _check(
      catalogue['policy_hash'] ==
          'sha256:${sha256.convert(policy.readAsBytesSync())}',
      'Hash must identify the written policy bytes',
    );
    for (final (offset, limit, returned) in [
      (1, 2, 2),
      (1000, 8, 1),
      (1002, 1, 0),
      (1, 9223372036854775807, 1000),
      (9223372036854775807, 9223372036854775807, 0),
    ]) {
      final page = decoded(
        (await invoke(['node', '--offset=$offset', '--limit=$limit'], 0)).out,
      )['payload'];
      _check(
        sameJson(
          [page['total'], page['omitted'], page['offset'], page['limit']],
          [1001, 1001 - returned, offset, limit],
        ),
        'Pagination totals: $offset/$limit',
      );
      _check(
        page['nodes'].length == returned,
        'Pagination node count: $offset/$limit',
      );
    }
    final diagram = await invoke(['export', '--format', 'mermaid'], 0);
    final text = utf8.decode(diagram.out);
    _check(
      ' --> '.allMatches(text).length == 1001 &&
          '["'.allMatches(text).length == 1001,
      'Diagram must retain all edges and node labels',
    );
    _check(text.contains('n1000 --> n0\n'), 'Cycle-closing diagram edge');
    _check(
      sameJson(
        (await invoke(['export', '--format=mermaid'], 0)).out,
        diagram.out,
      ),
      'Equivalent format spelling changed diagram bytes',
    );
    _check(
      decoded(diagram.err)['diagnostics'][0]['code'] == 'POLICY_CYCLE',
      'Cycle warning',
    );
    final fileArgs = ['export', '--format', 'mermaid', '--out', 'graph.mmd'];
    await invoke(fileArgs, 0);
    _check(
      sameJson(at('graph.mmd').readAsBytesSync(), diagram.out),
      'Created diagram bytes',
    );
    await invoke(fileArgs, 2);
    _check(
      sameJson(at('graph.mmd').readAsBytesSync(), diagram.out),
      'Conflict changed output',
    );
    await invoke([...fileArgs, '--overwrite'], 0);
    _check(
      sameJson(at('graph.mmd').readAsBytesSync(), diagram.out),
      'Overwritten diagram bytes',
    );
    final link = Link(at('link.mmd').path)..createSync('missing-target');
    final conflict = await invoke([
      'export',
      '--format',
      'mermaid',
      '--out',
      'link.mmd',
    ], 2);
    _check(
      decoded(conflict.err)['diagnostics'].last['code'] ==
          'EXPORT_TARGET_EXISTS',
      'Dangling link conflict',
    );
    _check(
      link.existsSync() && !at('missing-target').existsSync(),
      'Dangling link was altered',
    );
    await invoke([
      'export',
      '--format',
      'mermaid',
      '--out',
      'missing/graph.mmd',
    ], 2);
    final outside = Directory(p.join(base.path, 'outside'))..createSync();
    Link(at('escape').path).createSync(outside.path);
    final old = File(p.join(outside.path, 'old.mmd'))
      ..writeAsStringSync('outside work');
    for (final (name, flags) in [
      ('new.mmd', <String>[]),
      ('old.mmd', ['--overwrite']),
    ]) {
      await invoke([
        'export',
        '--format',
        'mermaid',
        '--out',
        'escape/$name',
        ...flags,
      ], 2);
    }
    _check(
      !File(p.join(outside.path, 'new.mmd')).existsSync(),
      'Created output outside root',
    );
    _check(
      sameJson(old.readAsBytesSync(), utf8.encode('outside work')),
      'Overwrote outside work',
    );
    Directory(at('nested').path).createSync();
    final rootAlias = Link(p.join(base.path, 'selected-root-link'))
      ..createSync(root.path);
    final selected = await capture(executable, [
      '--root',
      rootAlias.path,
      'export',
      '--format',
      'mermaid',
      '--out',
      'nested/graph.mmd',
    ], env: environment);
    _check(
      selected.code == 0 && selected.out.isEmpty,
      'Selected root alias transport: $selected',
    );
    validate(export, selected.err);
    _check(
      sameJson(at('nested/graph.mmd').readAsBytesSync(), diagram.out),
      'Selected alias output bytes',
    );
    count++;
    final directory = Directory(at('directory.mmd').path)..createSync();
    await invoke([
      'export',
      '--format',
      'mermaid',
      '--out',
      'directory.mmd',
      '--overwrite',
    ], 2);
    _check(directory.existsSync(), 'Nonregular output directory was replaced');
    if (Platform.isWindows) {
      final locked = at('locked.mmd')
        ..writeAsStringSync('keep existing output');
      final lock = ExclusiveWindowsFileLock(locked.path);
      late _Captured failure;
      try {
        failure = await invoke([
          'export',
          '--format',
          'mermaid',
          '--out',
          'locked.mmd',
          '--overwrite',
        ], 2);
      } finally {
        lock.close();
      }
      _check(
        decoded(failure.err)['diagnostics'].last['code'] ==
            'EXPORT_WRITE_FAILED',
        'Sharing conflict diagnostic',
      );
      _check(
        sameJson(locked.readAsBytesSync(), utf8.encode('keep existing output')),
        'Sharing conflict changed bytes',
      );
      stdout.writeln(
        'Windows mechanisms: non-regular directory rejection and real sharing conflict; '
        'POSIX FIFO/RLIMIT_FSIZE are inapplicable. Partial-write/flush/close faults '
        'are required separately in native_fault_process_smoke.',
      );
    } else {
      final pipe = at('pipe.mmd');
      createNonregularResource(pipe.path);
      try {
        await invoke([
          'export',
          '--format',
          'mermaid',
          '--out',
          'pipe.mmd',
          '--overwrite',
        ], 2);
      } finally {
        removeNonregularResource(pipe.path);
      }
      final failure = await invoke(
        ['export', '--format', 'mermaid', '--out', 'partial.mmd'],
        2,
        limitOutput: true,
      );
      _check(
        decoded(failure.err)['diagnostics'].last['code'] ==
            'EXPORT_WRITE_FAILED',
        'Partial-write diagnostic',
      );
      _check(
        sameJson(at('partial.mmd').readAsBytesSync(), [37]),
        'Must retain exactly the first % byte',
      );
    }
    final outcomes = await Future.wait([
      for (var i = 0; i < 8; i++)
        capture(
          executable,
          command(root, ['export', '--format', 'mermaid', '--out', 'race.mmd']),
          env: environment,
        ),
    ]);
    final codes = outcomes.map((result) => result.code).toList()..sort();
    _check(
      sameJson(codes, [0, 2, 2, 2, 2, 2, 2, 2]),
      'Race must have exactly one winner: $codes',
    );
    _check(
      sameJson(at('race.mmd').readAsBytesSync(), diagram.out),
      'Racing loser truncated winner',
    );
    for (final outcome in outcomes) {
      _check(outcome.out.isEmpty, 'Race emitted stdout');
      validate(export, outcome.err);
    }
    count += 8;
    for (final args in [
      ['export'],
      ['export', '--format', 'json'],
      ['export', '--format', 'mermaid', '--overwrite'],
      ['export', '--format', 'mermaid', '--out', '../outside'],
      ['node', '--limit', '0'],
      ['node', '--offset', '-1'],
    ]) {
      await invoke(args, 64);
    }
    policy.writeAsStringSync('[');
    final invalid = await invoke([
      'export',
      '--format',
      'mermaid',
      '--out',
      'invalid.mmd',
    ], 2);
    final value = decoded(invalid.err);
    _check(
      value['status'] == 'invalid_policy' && value['policy_hash'] != null,
      'Malformed policy retains hash',
    );
    _check(!at('invalid.mmd').existsSync(), 'Malformed policy created output');
    policy.deleteSync();
    _check(
      decoded(
            (await invoke(['export', '--format', 'mermaid'], 2)).err,
          )['status'] ==
          'error',
      'Missing policy status',
    );
    final missing = await capture(executable, [
      '--root',
      at('missing').path,
      'export',
      '--format',
      'mermaid',
    ], timeout: null);
    _check(
      missing.code == 64 && missing.out.isEmpty,
      'Missing root transport: $missing',
    );
    validate(export, missing.err);
    _check(
      sameJson(decoded(missing.err)['payload'], {
        'format': 'mermaid',
        'out': null,
      }),
      'Missing root payload',
    );
    count++;
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln(
    '$count native AOT catalogue/export/schema/safety cases passed',
  );
}

void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}
