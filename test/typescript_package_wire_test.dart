import 'dart:convert';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'typescript_packages_test.dart' show preparedFixture, edges;

class ObservedProcess implements Process {
  final Process process;
  final List<int> Function(List<int>) transform;
  ObservedProcess(this.process, this.transform);
  @override
  int get pid => process.pid;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  IOSink get stdin => process.stdin;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Stream<List<int>> get stdout async* {
    final bytes = await process.stdout.expand((chunk) => chunk).toList();
    yield transform(bytes);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      process.kill(signal);
}

Future<dynamic> transformedCheck(
  Directory root,
  List<int> Function(List<int>) transform,
) => Inspection(
  startProcess:
      (
        executable,
        arguments, {
        required workingDirectory,
        required environment,
      }) async {
        final process = await Process.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: false,
        );
        return arguments.contains('--version')
            ? process
            : ObservedProcess(process, transform);
      },
).check(RepositorySelection(root.path));

void main() {
  test(
    'manifest deleted after the producer responds uses changed-input semantics',
    () async {
      final root = await preparedFixture(
        'npm-v3-small',
        "import 'ansi-regex';\nimport '../core/private.js';\n",
      );
      final report = await transformedCheck(root, (bytes) {
        File('${root.path}/node_modules/ansi-regex/package.json').deleteSync();
        return bytes;
      });
      expect(report.status, 'incomplete');
      expect(report.payload['tool_errors'], isEmpty);
      expect(
        report.payload['unknowns'],
        contains(predicate((dynamic u) => u['code'] == 'INPUT_CHANGED')),
      );
      expect(
        edges(report).map((e) => e['resolution']['kind']),
        containsAll(['external', 'local']),
      );
    },
  );
  for (final corruption in ['identity', 'lock', 'target']) {
    test(
      'external helper $corruption corruption is structurally rejected',
      () async {
        final root = await preparedFixture(
          'npm-v3-small',
          "import 'ansi-regex';\n",
        );
        final report = await transformedCheck(root, (bytes) {
          final value = jsonDecode(utf8.decode(bytes)) as Map;
          final fact = (value['facts'] as List).single as Map;
          if (corruption == 'identity') {
            fact['resolution']['identity'] = 'npm:unrelated@1.0.0';
          } else {
            final inputs = {
              for (final input in value['inputs']) input['id']: input,
            };
            fact['input_ids'] = (fact['input_ids'] as List).where((id) {
              final input = inputs[id];
              return corruption == 'lock'
                  ? !input['observed_uri'].endsWith('/package-lock.json')
                  : input['canonical_uri'] == null ||
                        !input['canonical_uri'].endsWith(
                          '/ansi-regex/index.d.ts',
                        );
            }).toList();
          }
          return utf8.encode(jsonEncode(value));
        });
        expect(report.status, 'incomplete');
        expect(edges(report), isEmpty);
        expect(
          report.payload['tool_errors'],
          contains(
            predicate((dynamic e) => e['code'] == 'TYPESCRIPT_HELPER_FAILED'),
          ),
        );
      },
    );
  }
}
