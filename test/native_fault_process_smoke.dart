// Real host C fault substitution observed through the assembled CLI.
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void equal(Object? actual, Object? expected, String context) {
  check(
    const DeepCollectionEquality().equals(actual, expected),
    '$context: expected $expected, got $actual',
  );
}

Map<String, dynamic> document(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

const plan = 'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError(
      'Usage: dart test/native_fault_process_smoke.dart <executable>',
    );
  }
  final repo = File.fromUri(Platform.script).parent.parent;
  final temporary = Directory.systemTemp.createTempSync(
    'archway-native-fault-',
  );
  try {
    final base = Directory(temporary.resolveSymbolicLinksSync());
    final binary = stageInstallation(
      File(arguments.single),
      Directory(p.join(base.path, 'bundle')),
    );
    final target = nativeTarget();
    final asset = File(
      p.join(base.path, 'bundle', 'native', target.target, target.library),
    );
    final windows = target.target == 'windows-x64';
    final fixture = File(
      p.join(
        repo.path,
        'test',
        windows ? 'native_fault_windows_fixture.c' : 'native_fault_fixture.c',
      ),
    );
    await buildNativeLibrary(fixture, asset);
    var count = 0;
    Future<({NativeProcessResult result, List<String> closed})> invoke(
      String root,
      List<String> args,
      String fault,
      int expected,
    ) async {
      final log = File(p.join(base.path, 'close.log'))..writeAsStringSync('');
      final result = await runNativeProcess(
        [binary.path, '--root', root, ...args],
        timeout: const Duration(seconds: 10),
        environment: {
          ...Platform.environment,
          'ARCHWAY_TEST_FAULT': fault,
          'ARCHWAY_TEST_CLOSE_LOG': log.path,
        },
      );
      equal(result.exitCode, expected, '$fault process $result');
      count++;
      return (result: result, closed: log.readAsLinesSync());
    }

    var root = Directory(p.join(base.path, 'export'))..createSync();
    File(p.join(root.path, 'architecture.yaml')).writeAsStringSync(plan);
    final baseline = await invoke(
      root.path,
      ['export', '--format', 'mermaid'],
      '',
      0,
    );
    equal(baseline.closed, <String>[], 'Baseline close log');
    equal(
      document(baseline.result.stderr)['diagnostics'][0]['code'],
      'EMPTY_PLAN',
      'Baseline diagnostic',
    );
    final output = File(p.join(root.path, 'out.mmd'));
    for (final fault in [
      'partial',
      windows ? 'aborted' : 'interrupted',
      'zero',
      'flush',
      'close',
      'validate',
    ]) {
      output.writeAsStringSync('keep this');
      final success = fault == 'partial' || fault == 'interrupted';
      final run = await invoke(
        root.path,
        ['export', '--format', 'mermaid', '--out', 'out.mmd', '--overwrite'],
        fault,
        success ? 0 : 2,
      );
      equal(run.result.stdout, <int>[], '$fault export stdout');
      equal(run.closed, ['file', 'directory'], '$fault export close log');
      final diagnostics = document(run.result.stderr)['diagnostics'] as List;
      equal(
        (success ? diagnostics.first : diagnostics.last)['code'],
        success ? 'EMPTY_PLAN' : 'EXPORT_WRITE_FAILED',
        '$fault export diagnostic',
      );
      final expected = fault == 'validate'
          ? utf8.encode('keep this')
          : fault == 'zero' || fault == 'aborted'
          ? <int>[]
          : baseline.result.stdout;
      equal(output.readAsBytesSync(), expected, '$fault export bytes');
    }

    for (final fault in [
      'partial',
      windows ? 'aborted' : 'interrupted',
      'zero',
      'flush',
      'close',
      'observe',
    ]) {
      root = Directory(p.join(base.path, 'init-$fault'))..createSync();
      final success = fault == 'partial' || fault == 'interrupted';
      final run = await invoke(
        root.path,
        ['init', '--template', 'mixed'],
        fault,
        success ? 0 : 2,
      );
      equal(run.result.stderr, <int>[], '$fault init stderr');
      final payload = document(run.result.stdout)['payload'] as Map;
      equal(
        payload['outcome'],
        success ? 'created' : 'partial',
        '$fault outcome',
      );
      final created = success
          ? ['architecture.yaml', 'ARCHITECTURE.md']
          : ['architecture.yaml'];
      equal(payload['created_paths'], created, '$fault created paths');
      equal(
        payload['residual_paths'],
        success ? [] : created,
        '$fault residual paths',
      );
      final entries = root.listSync().map((e) => p.basename(e.path)).toList()
        ..sort();
      equal(entries, [...created]..sort(), '$fault directory inventory');
      equal(
        run.closed,
        success ? ['file', 'file', 'directory'] : ['file', 'directory'],
        '$fault init close log',
      );
      final architecture = File(p.join(root.path, 'architecture.yaml'));
      if (success) {
        equal(
          architecture.readAsStringSync(),
          '# Archway: mixed template\n$plan',
          '$fault init content',
        );
      }
      if (['zero', 'observe', 'aborted'].contains(fault)) {
        equal(
          architecture.readAsBytesSync(),
          <int>[],
          '$fault empty init bytes',
        );
      }
    }
    final alias = Link(p.join(base.path, 'alias'))..createSync(root.path);
    final aliasRun = await invoke(
      alias.path,
      ['validate'],
      windows ? 'alias_invalid' : 'alias_full',
      2,
    );
    equal(aliasRun.result.stderr, <int>[], 'Alias stderr');
    equal(aliasRun.closed, <String>[], 'Alias close log');
    final diagnostic =
        document(aliasRun.result.stdout)['diagnostics'][0] as Map;
    equal(diagnostic['code'], 'ROOT_ACCESS_FAILED', 'Alias diagnostic');
    check(
      (diagnostic['message'] as String).contains(
        windows ? 'win32 4392' : 'Symbolic link target exceeds limit',
      ),
      'Alias message: $diagnostic',
    );

    // Negative control: retry genuinely consumed ownership in the real bridge.
    final original = File(p.join(repo.path, 'native', target.source))
        .readAsStringSync();
    final closeOnce = windows
        ? 'return CloseHandle(handle(value)) ? ok(0) : win32_failed(GetLastError());'
        : 'return close(descriptor(handle)) < 0 ? failed(errno) : ok(0);';
    final retry = windows
        ? 'if (!CloseHandle(handle(value))) { DWORD error = GetLastError(); '
              '(void)CloseHandle(handle(value)); return win32_failed(error); } return ok(0);'
        : 'if (close(descriptor(handle)) < 0) { int error = errno; '
              '(void)close(descriptor(handle)); return failed(error); } return ok(0);';
    equal(
      closeOnce.allMatches(original).length,
      1,
      'Unique close mutation seam',
    );
    final bridge = File(p.join(base.path, 'retry_bridge.c'))
      ..writeAsStringSync(original.replaceAll(closeOnce, retry));
    final fixtureSource = fixture.readAsStringSync();
    final include = '#include "${target.source}"';
    equal(
      include.allMatches(fixtureSource).length,
      1,
      'Unique fixture include seam',
    );
    final mutant = File(p.join(base.path, 'retry_fixture.c'))
      ..writeAsStringSync(
        fixtureSource.replaceAll(
          include,
          '#include "${bridge.path.replaceAll('\\', '/')}"',
        ),
      );
    await buildNativeLibrary(mutant, asset);
    final mutantRoot = Directory(p.join(base.path, 'mutant-export'))
      ..createSync();
    File(p.join(mutantRoot.path, 'architecture.yaml')).writeAsStringSync(plan);
    final mutantRun = await invoke(
      mutantRoot.path,
      ['export', '--format', 'mermaid', '--out', 'out.mmd'],
      'close',
      2,
    );
    equal(
      (document(mutantRun.result.stderr)['diagnostics'] as List).last['code'],
      'EXPORT_WRITE_FAILED',
      'Mutant diagnostic',
    );
    equal(mutantRun.closed, [
      'file',
      windows ? 'invalid' : 'directory',
      'directory',
    ], 'Retried consumed handle must be visible');
    equal(count, 15, 'Complete native fault scenario inventory');
    stdout.writeln('$count ${target.target} native fault CLI cases passed');
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
