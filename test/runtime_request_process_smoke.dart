// Genuine long-path corpus through the installed CLI, with no encoder override.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// Extended Win32 spelling belongs only to fixture setup, rename and cleanup.
// The CLI receives the ordinary root and enumerates the native corpus itself.
String fixturePath(String path) {
  if (!Platform.isWindows || path.startsWith(r'\\?\')) return path;
  check(p.isAbsolute(path), 'Expected absolute native fixture path: $path');
  path = p.normalize(path);
  return path.startsWith(r'\\')
      ? '\\\\?\\UNC\\${path.substring(2)}'
      : '\\\\?\\$path';
}

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 3) {
    throw ArgumentError(
      'Usage: dart test/runtime_request_process_smoke.dart '
      '<executable> <node> [coverage-failure.json]',
    );
  }
  final repository = File.fromUri(Platform.script).parent.parent;
  final executable = File(File(arguments[0]).resolveSymbolicLinksSync());
  final node = File(File(arguments[1]).resolveSymbolicLinksSync());
  final failureReport = arguments.length == 3
      ? File(p.normalize(p.absolute(arguments[2])))
      : null;
  final schema = ContractSchema(
    jsonDecode(
      File(p.join(repository.path, 'contracts/json/public-result.schema.json'))
          .readAsStringSync(),
    ),
  );
  final protocol = jsonDecode(
    File(p.join(repository.path, 'contracts/helper/request.schema.json'))
        .readAsStringSync(),
  )['properties']['protocol_version']['const'];
  final temporary = Directory.systemTemp.createTempSync('archway-request-');
  try {
    final base = Directory(temporary.resolveSymbolicLinksSync());
    final install = Directory(p.join(base.path, 'installation'));
    final binary = stageInstallation(executable, install);
    final root = Directory(p.join(base.path, 'project'))..createSync();
    File(p.join(root.path, 'architecture.yaml')).writeAsStringSync('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes: [{id: all, responsibility: All, owns: [src/], allows: [], public: []}]
''');
    File(p.join(root.path, 'tsconfig.json')).writeAsStringSync('{}');
    final request = <String, Object?>{
      'protocol_version': protocol,
      'request_id': 'check:web',
      'project_id': 'web',
      'root_uri': Uri.file(root.path, windows: Platform.isWindows).toString(),
      'config_path': 'tsconfig.json',
      'expected_files': <String>[],
    };
    int requestBytes() => utf8.encode(jsonEncode(request)).length;
    const limit = 8 * 1024 * 1024;
    // More files rather than deeper names keeps full paths below macOS limits.
    final prefix = 'src/${List.filled(3, 'a' * 190).join('/')}';
    final first = '$prefix/file-00000.ts';
    // Each element costs its ASCII path, quotes and comma; no final comma.
    final available = limit - requestBytes() + 1;
    var count = available ~/ (first.length + 3);
    var rest = available - count * (first.length + 3);
    if (rest < 12) {
      count--;
      rest += first.length + 3;
    }
    final paths = [
      for (var i = 0; i < count; i++)
        '$prefix/file-${i.toString().padLeft(5, '0')}.ts',
    ];
    final targetLength = rest - 3;
    var tail = 'src/';
    while (targetLength - tail.length > 203) {
      tail += '${'z' * 190}/';
    }
    tail += '${'z' * (targetLength - tail.length - 3)}.ts';
    paths.add(tail);
    request['expected_files'] = [...paths]..sort();
    check(requestBytes() == limit, 'Corpus does not encode to exact 8 MiB');
    File corpusFile(String path) =>
        File(fixturePath(p.joinAll([root.path, ...path.split('/')])));
    try {
      for (final path in paths) {
        final file = corpusFile(path);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('export {};\n');
      }
      final marker = File(p.join(base.path, 'request-size'));
      File(p.join(install.path, 'assets/typescript/helper.cjs'))
          .writeAsStringSync(
            "const chunks=[];process.stdin.on('data',b=>chunks.push(b));"
            "process.stdin.on('end',()=>{"
            "const raw=Buffer.concat(chunks),r=JSON.parse(raw);"
            "require('node:fs').writeFileSync(${jsonEncode(marker.path)},"
            'String(raw.length));process.stdout.write(JSON.stringify({'
            'protocol_version:r.protocol_version,request_id:r.request_id,'
            "project_id:r.project_id,status:'failed',"
            'files:r.expected_files.map(path=>({path,'
            "membership:'unknown',coverage:'failed',input_id:null})),"
            'facts:[],inputs:[],unknowns:[],tool_errors:['
            "{code:'REQUEST_ACCEPTED',message:'Accepted exact request',"
            'path:null,source_range:null}]}));});',
          );
      Future<Map<String, dynamic>> invoke(String code) async {
        final result = await runNativeProcess(
          [binary.path, '--root', root.path, 'check'],
          workingDirectory: base.path,
          environment: {
            // Windows keys are case-insensitive, unlike Dart maps.
            for (final entry in Platform.environment.entries)
              if (entry.key.toUpperCase() != 'PATH') entry.key: entry.value,
            'PATH': node.parent.path,
          },
          timeout: const Duration(seconds: 90),
        );
        check(
          result.exitCode == 2 && result.stderr.isEmpty,
          'Exit/stderr: ${result.exitCode}, '
          '${utf8.decode(result.stderr, allowMalformed: true)}',
        );
        check(
          result.stdout.isNotEmpty &&
              result.stdout.last == 10 &&
              result.stdout.where((byte) => byte == 10).length == 1,
          'Expected exactly one complete public JSON line',
        );
        final value =
            jsonDecode(utf8.decode(result.stdout)) as Map<String, dynamic>;
        final errors = schema.errors(value);
        check(errors.isEmpty, 'Public schema: $errors');
        final payload = value['payload'] as Map<String, dynamic>;
        check(
          value['exit_code'] == 2 && payload['analysis_complete'] == false,
          'Expected incomplete public exit 2',
        );
        final coverage = payload['coverage']['files'] as List;
        if (coverage.length != paths.length) {
          try {
            failureReport?.writeAsBytesSync(result.stdout);
            final actual = coverage
                .map((entry) => entry['path'] as String)
                .toSet();
            final expected = paths.toSet();
            stderr.writeln(
              jsonEncode({
                'request_coverage_mismatch': {
                  'expected_count': paths.length,
                  'actual_count': coverage.length,
                  'missing_sample':
                      (expected.difference(actual).toList()..sort())
                          .take(3)
                          .toList(),
                  'unexpected_sample':
                      (actual.difference(expected).toList()..sort())
                          .take(3)
                          .toList(),
                  'observed': payload['observed'],
                  'unknowns': (payload['unknowns'] as List).take(8).toList(),
                  'tool_errors': (payload['tool_errors'] as List)
                      .take(8)
                      .toList(),
                  'helper_request_bytes': marker.existsSync()
                      ? marker.readAsStringSync()
                      : null,
                  'full_report': failureReport?.path,
                },
              }),
            );
          } catch (error) {
            stderr.writeln(
              jsonEncode({'request_coverage_diagnostic_error': '$error'}),
            );
          }
        }
        check(
          coverage.length == paths.length,
          'Incomplete request corpus coverage',
        );
        check((payload['facts']['edges'] as List).isEmpty, 'Unexpected edges');
        check(
          (payload['tool_errors'] as List).any(
            (error) => error['code'] == code,
          ),
          'Missing $code: ${payload['tool_errors']}',
        );
        return value;
      }

      await invoke('REQUEST_ACCEPTED');
      check(
        marker.readAsStringSync() == '$limit',
        'Helper saw wrong byte count',
      );
      marker.deleteSync();
      final changed = '${tail.substring(0, tail.length - 3)}z.ts';
      final expectedContents = utf8.encode('export {};\n');
      check(
        sameJson(corpusFile(tail).readAsBytesSync(), expectedContents),
        'Native corpus contents differ before rename',
      );
      corpusFile(tail).renameSync(corpusFile(changed).path);
      check(
        sameJson(corpusFile(changed).readAsBytesSync(), expectedContents),
        'Native corpus contents changed after rename',
      );
      paths[paths.length - 1] = changed;
      request['expected_files'] = [...paths]..sort();
      check(requestBytes() == limit + 1, 'Corpus does not encode to 8 MiB + 1');
      final result = await invoke('TYPESCRIPT_HELPER_FAILED');
      check(
        (result['payload']['tool_errors'][0]['message'] as String).contains(
          'request exceeds 8 MiB',
        ),
        'Missing oversize request diagnostic',
      );
      check(!marker.existsSync(), 'Oversize request launched a helper');
    } finally {
      final corpus = Directory(fixturePath(p.join(root.path, 'src')));
      if (corpus.existsSync()) corpus.deleteSync(recursive: true);
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
  stdout.writeln('2 real request byte-boundary/schema checks passed.');
}
