import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../contracts/json/entrypoint_oracle.dart' as oracle;
import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';

/// Supplementary real AOT/schema checks against the independent policy oracle.
/// Runs the supplied executable with no discoverable runtime; not another OS's
/// acceptance and not a replacement for owning-seam tests.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart test/plan_query_process_smoke.dart <executable>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(arguments.single).absolute.path;
  final contracts = Directory.fromUri(
    Platform.script.resolve('../contracts/json/'),
  );
  Map fixture(String name) =>
      jsonDecode(File('${contracts.path}/$name').readAsStringSync());
  final schema = ContractSchema(fixture('public-result.schema.json'));
  final index = jsonDecode(
    File('${contracts.path}/fixture-index.json').readAsStringSync(),
  ) as List;
  final temporary = Directory.systemTemp.createTempSync('archway-plan-query-');
  var count = 0;
  try {
    final root = Directory('${temporary.path}/root café')..createSync();
    final cwd = Directory('${temporary.path}/other cwd')..createSync();
    final policyFile = File('${root.path}/architecture.yaml');
    Future<Map> invoke(List<String> args, int expectedExit) async {
      final process = await Process.start(
        executable,
        ['--root', root.path, ...args],
        workingDirectory: cwd.path,
        environment: {...Platform.environment, 'PATH': '/no-runtime-here'},
      );
      await process.stdin.close();
      final completion = Future.wait<Object>([
        process.exitCode,
        process.stdout.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        ),
        process.stderr.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        ),
      ]);
      final outputs = await completion.timeout(
        const Duration(seconds: 10),
        onTimeout: () async {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
          throw TimeoutException('Plan/query process timed out: $args');
        },
      );
      final actualExit = outputs[0] as int;
      final stdout = outputs[1] as List<int>, stderr = outputs[2] as List<int>;
      _check(
        actualExit == expectedExit,
        '$args: exit $actualExit, stdout=$stdout, stderr=$stderr',
      );
      _check(stderr.isEmpty, '$args: unexpected stderr');
      _check(
        stdout.where((byte) => byte == 10).length == 1 && stdout.last == 10,
        '$args: stdout must be one newline-terminated JSON value',
      );
      final value = jsonDecode(utf8.decode(stdout)) as Map;
      final errors = schema.errors(value);
      _check(errors.isEmpty, '$args: $errors');
      _check(value['exit_code'] == actualExit, '$args: envelope exit mismatch');
      count++;
      return value;
    }

    for (final entry in index) {
      if (entry['schema'] != 'policy') continue;
      policyFile.writeAsBytesSync(
        File('${contracts.path}/${entry['file']}').readAsBytesSync(),
      );
      final result = await invoke(['validate'], entry['valid'] ? 0 : 2);
      _check(
        result['status'] == (entry['valid'] ? 'ok' : 'invalid_policy'),
        '$entry: policy status',
      );
      _check(
        result['policy_hash'] ==
            'sha256:${sha256.convert(policyFile.readAsBytesSync())}',
        '$entry: policy hash',
      );
      if (entry['valid']) {
        final policy = jsonDecode(policyFile.readAsStringSync());
        _check(
          sameJson(result['payload'], {
            'policy_valid': true,
            'projects': policy['projects'].length,
            'nodes': policy['nodes'].length,
          }),
          '$entry: validation payload',
        );
      } else {
        _check(
          result['payload'] == null &&
              (result['diagnostics'] as List).isNotEmpty,
          '$entry: invalid policy evidence',
        );
      }
    }
    for (final entry in index) {
      if (!entry.containsKey('policy') || entry['valid'] != true) continue;
      final expected = fixture(entry['file']);
      if (expected['command'] != 'allows') continue;
      policyFile.writeAsBytesSync(
        File('${contracts.path}/${entry['policy']}').readAsBytesSync(),
      );
      final payload = expected['payload'];
      final args = payload['mode'] == 'ids'
          ? ['allows', payload['from_id'] as String, payload['to_id'] as String]
          : [
              'allows',
              '--paths',
              payload['from']['path'] as String,
              payload['to']['path'] as String,
            ];
      final result = await invoke(args, expected['exit_code']);
      _check(sameJson(result['payload'], payload), '$entry: linked payload');
      oracle.verifyLinked(result, jsonDecode(policyFile.readAsStringSync()));
    }
    policyFile.writeAsBytesSync(
      File('${contracts.path}/fixtures/policy-entrypoints.json')
          .readAsBytesSync(),
    );
    for (final args in [
      ['owner', 'src/app/planned.ts'],
      ['owner', 'outside/file'],
      ['node', 'app'],
      ['node', '--path', 'src/app/planned.ts'],
      ['node', '--path', 'outside/file'],
      ['node', 'missing'],
      ['allows', 'app', 'missing'],
    ]) {
      await invoke(
        args,
        args.contains('missing')
            ? 2
            : args.contains('outside/file')
            ? 1
            : 0,
      );
    }
    for (final args in [
      ['owner'],
      ['owner', '../escape'],
      ['owner', 'C:relative'],
      ['owner', 'src/[x]'],
      ['node', 'app', '--path', 'src/app/a'],
      ['node', '--path'],
      ['node', 'app', '--limit', '1'],
      ['allows', '--paths', 'src/app/', 'src/app/a'],
      ['allows', '--paths', '.', 'src/app/a'],
      ['allows', '--paths', 'src/app/a', 'src/app/x/..'],
      ['allows', '--paths=foo', 'x', 'y'],
      ['allows', 'app'],
      ['allows', 'app', 'pricing', 'extra'],
      ['owner', '--json', 'src/app/a'],
      ['owner', '--policy', 'a', '--policy', 'b', 'src/app/a'],
    ]) {
      final value = await invoke(args, 64);
      _check(
        value['payload'] == null && value['policy_hash'] == null,
        '$args: usage payload',
      );
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
  stdout.writeln(
    '$count real plan/query process/schema checks passed (runtime PATH cleared).',
  );
}

void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}
