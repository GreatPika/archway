// Public CLI rechecks genuine hop-only evidence after an earlier route fails.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/installation_staging.dart';

typedef _Captured = ({int code, List<int> out, List<int> err});

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run test/alias_hop_recheck_process_smoke.dart <executable> <node>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(arguments[0]);
  final node = File(arguments[1]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-independent-hop-')
        .resolveSymbolicLinksSync(),
  );
  try {
    final install = Directory(p.join(base.path, 'install'))..createSync();
    final binary = stageInstallation(executable, install);
    final root = Directory(p.join(base.path, 'root'));
    File at(String name) => File(p.join(root.path, name));
    for (final name in ['src', 'empty', 'other']) {
      Directory(p.join(root.path, name)).createSync(recursive: true);
    }
    final first = jsonEncode(at('src/first').path);
    final second = jsonEncode(at('second').path);
    final firstTarget = '..${Platform.pathSeparator}second';
    // Node creates actual directory symlinks on every target, preserving raw
    // relative spelling rather than Dart's Windows junction normalization.
    final links = await capture(node, [
      '-e',
      '''const fs = require('fs');
fs.symlinkSync('empty', $second, 'dir');
fs.symlinkSync(${jsonEncode(firstTarget)}, $first, 'dir');
process.stdout.write(JSON.stringify(fs.readlinkSync($first)));
''',
    ]);
    _check(
      links.code == 0,
      'Directory-hop setup failed: ${utf8.decode(links.err)}',
    );
    _check(
      jsonDecode(utf8.decode(links.out)) == firstTarget,
      'Raw first hop changed',
    );
    _check(
      Directory(at('src/first').path).existsSync(),
      'Directory-hop fixture is not traversable',
    );
    at('src/main.ts').writeAsStringSync('export {};');
    at('tsconfig.json').writeAsStringSync(
      jsonEncode({
        'extends': './src/first/missing.json',
        'include': ['src/main.ts'],
      }),
    );
    at('architecture.yaml').writeAsStringSync('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: [src/first/]
nodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]
''');
    final helper = File(p.join(install.path, 'assets/typescript/helper.cjs'));
    final captured = await capture(
      node,
      [helper.path],
      input: jsonEncode({
        'protocol_version': 2,
        'request_id': 'check:web',
        'project_id': 'web',
        'root_uri': root.uri.toString().replaceFirst(RegExp(r'/$'), ''),
        'config_path': 'tsconfig.json',
        'expected_files': ['src/main.ts'],
      }),
    );
    _check(
      captured.code == 0,
      'Genuine helper failed: ${utf8.decode(captured.err)}',
    );
    final response = jsonDecode(utf8.decode(captured.out)) as Map;
    // Isolate genuine absent-route evidence from redundant directory probes.
    final standalone = {
      at('second').uri.toString(),
      at('src/first').uri.toString(),
    };
    response['inputs'] = (response['inputs'] as List)
        .where((item) => !standalone.contains(item['observed_uri']))
        .toList();
    _check(
      (response['inputs'] as List).any(
        (item) =>
            item['kind'] == 'absent' &&
            (item['symlink_hops'] as List).length == 2,
      ),
      'Genuine absent input must retain both symlink hops',
    );
    final encoded = base64Encode(utf8.encode(jsonEncode(response)));
    helper.writeAsStringSync('''let input = '';
process.stdin.on('data', bytes => input += bytes);
process.stdin.on('end', () => {
  const fs = require('fs');
  fs.unlinkSync($first); fs.symlinkSync('first', $first, 'dir');
  fs.unlinkSync($second); fs.symlinkSync('other', $second, 'dir');
  process.stdout.write(Buffer.from('$encoded', 'base64'));
});
''');
    final result = await capture(
      binary.path,
      ['--root', root.path, 'check'],
      environment: {...Platform.environment, 'PATH': p.dirname(node)},
    );
    _check(
      result.code == 2 && result.err.isEmpty,
      'Expected exit 2 and silent stderr: $result',
    );
    _check(
      result.out.where((byte) => byte == 10).length == 1,
      'Expected one public JSON line',
    );
    final value = jsonDecode(utf8.decode(result.out)) as Map;
    final errors = schema.errors(value);
    _check(errors.isEmpty, 'Invalid public schema: $errors');
    final payload = value['payload'] as Map;
    _check(
      (payload['tool_errors'] as List).any(
        (error) => error['code'] == 'INPUT_RECHECK_FAILED',
      ),
      'Missing INPUT_RECHECK_FAILED',
    );
    _check(
      (payload['input_identity']['changed_inputs'] as List).any(
        (item) => sameJson(item, {
          'kind': 'repository',
          'path': 'src/first/missing.json',
        }),
      ),
      'Missing independent changed input: ${payload['input_identity']}',
    );
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln('1 bounded independent hop-only evidence recheck passed');
}

Future<_Captured> capture(
  String program,
  List<String> arguments, {
  String input = '',
  Duration timeout = const Duration(seconds: 30),
  Map<String, String>? environment,
}) async {
  final child = await Process.start(
    program,
    arguments,
    environment: environment ?? Platform.environment,
    includeParentEnvironment: false,
  );
  final out = <int>[], err = <int>[];
  final eofs = [Completer<void>(), Completer<void>()];
  final subscriptions = <StreamSubscription<List<int>>>[];
  var exited = false, failed = false;
  final completion = Future.wait<Object?>([
    child.exitCode.then((code) {
      exited = true;
      return code;
    }),
    ...eofs.map((done) => done.future),
    () async {
      child.stdin.add(utf8.encode(input));
      await child.stdin.close();
    }(),
  ], eagerError: true);
  completion.ignore();
  try {
    final streams = [child.stdout, child.stderr];
    final buffers = [out, err];
    for (var index = 0; index < streams.length; index++) {
      final done = eofs[index];
      subscriptions.add(
        streams[index].listen(
          buffers[index].addAll,
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
        ),
      );
    }
    final results = await completion.timeout(timeout);
    return (code: results.first as int, out: out, err: err);
  } on TimeoutException {
    failed = true;
    throw TimeoutException('$arguments timed out; stdout=$out; stderr=$err');
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    Object? failure;
    StackTrace? trace;
    try {
      if (!exited) {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode.timeout(const Duration(seconds: 2));
      }
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    try {
      // A deadline and direct-child exit do not dispose descendant-held pipes.
      // Start both cancellations even if one fails.
      await Future.wait(
        subscriptions.map((stream) async => await stream.cancel()),
      ).timeout(const Duration(seconds: 2));
    } catch (error, stack) {
      failure ??= error;
      trace ??= stack;
    } finally {
      for (final done in eofs) {
        if (!done.isCompleted)
          done.completeError(StateError('Capture closed before EOF'));
      }
    }
    if (!failed && failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}

void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}
