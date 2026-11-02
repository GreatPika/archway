// Real prepared Flutter AOT checks. Preparation is separate from inspection.
// No pub, Flutter, project code or builds; Linux tracing is host evidence only.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/flutter_sdk_copy.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// With strace -xx each printed string is a quoted sequence of UTF-8 bytes.
// Match complete executable/argv fields rather than parsing general strace text.
void validateFlutterTrace(
  String calls, {
  required String executable,
  required String embedded,
  required String root,
}) {
  String hex(String value) =>
      '"${utf8.encode(value).map((byte) => '\\x${byte.toRadixString(16).padLeft(2, '0')}').join()}"';
  String launch(String program, List<String> args) =>
      'execve(${hex(program)}, [${[program, ...args].map(hex).join(', ')}],';
  final launches = const LineSplitter()
      .convert(calls)
      .where((line) => line.contains('execve('))
      .toList();
  check(launches.length == 2, 'Unexpected launches: $launches');
  check(
    launches[0].contains(launch(executable, ['--root', root, 'check'])),
    'Unexpected Archway executable or arguments: $launches',
  );
  check(
    launches[1].contains(
      launch(embedded, ['--suppress-analytics', '--version']),
    ),
    'Unexpected embedded SDK executable or arguments: $launches',
  );
  check(!calls.contains('connect('), 'Unexpected network connection: $calls');
}

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run test/dart_flutter_process_smoke.dart '
      '<executable> <Flutter SDK> <prepared fixture>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(args[0]).resolveSymbolicLinksSync();
  final flutter = Directory(args[1]).resolveSymbolicLinksSync();
  final fixture = Directory(args[2]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory(p.dirname(flutter))
        .createTempSync('archway-flutter-process-')
        .resolveSymbolicLinksSync(),
  );
  final trace = Platform.environment['ARCHWAY_SYSCALL_TRACE'] == '1';
  var count = 0;
  try {
    final sdk = Directory(p.join(base.path, 'Flutter café SDK'));
    copyFlutterSdk(Directory(flutter), sdk);
    final marker = File(p.join(base.path, 'launcher-executed'));
    for (final name
        in Platform.isWindows
            ? ['dart.bat', 'flutter.bat']
            : ['dart', 'flutter']) {
      final launcher = File(p.join(sdk.path, 'bin', name));
      launcher.deleteSync(); // Never write through into the installed SDK.
      launcher.writeAsStringSync(
        Platform.isWindows
            ? '@echo off\r\necho invoked > "${marker.path}"\r\nexit /b 99\r\n'
            : '#!/bin/sh\necho invoked > "${marker.path}"\nexit 99\n',
      );
      makeFlutterLauncherExecutable(launcher);
    }
    final runtimeBin = Platform.isWindows
        ? p.join(sdk.path, 'bin', 'cache', 'dart-sdk', 'bin')
        : p.join(sdk.path, 'bin');
    final root = Directory(p.join(base.path, 'prepared app'));
    File at(String name) => File(p.join(root.path, name));
    for (final name in ['lib/app', 'lib/core', '.dart_tool']) {
      Directory(p.join(root.path, name)).createSync(recursive: true);
    }
    for (final name in ['pubspec.yaml', 'pubspec.lock']) {
      File(p.join(fixture, name)).copySync(at(name).path);
    }
    final config = jsonDecode(
      File(p.join(fixture, '.dart_tool', 'package_config.json'))
          .readAsStringSync(),
    ) as Map;
    // Match Python Path.as_uri (no trailing slash). Hosted/plugin package roots
    // outside Flutter stay exactly as prepared; only SDK-owned roots relocate.
    final oldUri = Uri.file(flutter).toString();
    final newUri = Uri.file(sdk.path).toString();
    for (final entry in config['packages']) {
      final uri = entry['rootUri'] as String;
      if (uri.startsWith(oldUri)) {
        entry['rootUri'] = uri.replaceFirst(oldUri, newUri);
      }
    }
    config['flutterRoot'] = newUri;
    at('.dart_tool/package_config.json').writeAsStringSync(jsonEncode(config));
    at('architecture.yaml').writeAsStringSync('''version: 1
projects:
  - {id: app, adapter: dart, package_roots: [./]}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''');
    at('lib/app/main.dart').writeAsStringSync(
      "import 'package:flutter/foundation.dart';\n"
      "import 'package:flutter_test/flutter_test.dart';\n"
      "import 'dart:ui';\nimport '../core/value.g.dart';\n"
      "part 'part.g.dart';\n",
    );
    at('lib/app/part.g.dart')
        .writeAsStringSync("part of 'main.dart'; class Part {}\n");
    at('lib/core/value.g.dart').writeAsStringSync('class Generated {}\n');
    Map<String, String> snapshot() => {
      for (final file
          in root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>())
        p.relative(file.path, from: root.path): sha256
            .convert(file.readAsBytesSync())
            .toString(),
    };
    Future<Map> invoke(int expected, {bool trace = false}) async {
      final before = snapshot();
      final traceFile = File(p.join(base.path, 'syscalls.log'));
      final result = await runNativeProcess(
        [
          if (trace) ...[
            '/usr/bin/strace',
            // Keep fixture paths/arguments untruncated (default is 32 bytes).
            '-s',
            '1048576',
            '-xx',
            '-f',
            '-qq',
            '-e',
            'trace=process,network',
            '-o',
            traceFile.path,
          ],
          executable,
          '--root',
          root.path,
          'check',
        ],
        workingDirectory: base.path,
        environment: {...Platform.environment, 'PATH': runtimeBin},
        timeout: const Duration(seconds: 60),
      );
      check(
        result.exitCode == expected,
        'Exit ${result.exitCode}, expected $expected: '
        '${utf8.decode(result.stdout)}; ${utf8.decode(result.stderr)}',
      );
      check(result.stderr.isEmpty, 'Unexpected stderr: ${result.stderr}');
      check(
        result.stdout.isNotEmpty &&
            result.stdout.last == 10 &&
            result.stdout.where((byte) => byte == 10).length == 1,
        'Expected one JSON line',
      );
      final value = jsonDecode(utf8.decode(result.stdout)) as Map;
      final errors = schema.errors(value);
      check(errors.isEmpty, 'Invalid public schema: $errors');
      check(value['exit_code'] == expected, 'Envelope exit mismatch');
      check(
        value['payload']['input_identity']['rechecked'] == true,
        'Inputs were not rechecked',
      );
      check(sameJson(snapshot(), before), 'Check mutated the prepared project');
      check(!marker.existsSync(), 'Check ran a Flutter launcher');
      if (trace) {
        validateFlutterTrace(
          traceFile.readAsStringSync(),
          executable: executable,
          embedded: p.join(
            sdk.path,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            Platform.isWindows ? 'dart.exe' : 'dart',
          ),
          root: root.path,
        );
      }
      count++;
      return value;
    }

    var value = await invoke(1, trace: trace);
    check(value['payload']['analysis_complete'] == true, 'Baseline incomplete');
    check(
      sameJson(value['payload']['observed'], {
        'files': 3,
        'analyzed_files': 3,
        'edges': 6,
      }),
      'Baseline observations',
    );
    check(
      (value['payload']['facts']['edges'] as List)
              .where((e) => e['resolution']['kind'] == 'builtin')
              .length ==
          3,
      'Expected three builtin edges',
    );
    void checkViolation(Map value) => check(
      sameJson(
        [for (final row in value['payload']['violations']) row['code']],
        ['DEPENDENCY_NOT_ALLOWED'],
      ),
      'Independent violation lost',
    );
    checkViolation(value);
    final manifest = File(p.join(sdk.path, 'bin/cache/flutter.version.json'));
    final manifestInput = (value['payload']['input_identity']['inputs'] as List)
        .firstWhere(
          (i) => i['location']['canonical_file_uri'] == manifest.uri.toString(),
        );
    check(
      manifestInput['hash'] ==
          'sha256:${sha256.convert(manifest.readAsBytesSync())}',
      'Flutter manifest hash mismatch',
    );

    final embedder = File(
      p.join(sdk.path, 'bin/cache/pkg/sky_engine/lib/_embedder.yaml'),
    );
    final embedderBytes = embedder.readAsBytesSync();
    final embedderText = utf8.decode(embedderBytes);
    check(
      embedderText.contains('"ui/ui.dart"'),
      'Prepared embedder mapping missing',
    );
    embedder.deleteSync();
    embedder.writeAsStringSync(
      embedderText.replaceAll('"ui/ui.dart"', '"ui/../ui/ui.dart"'),
    );
    value = await invoke(1);
    Map uiEdge(Map value) =>
        (value['payload']['facts']['edges'] as List).firstWhere(
          (e) => e['specifier'] == 'dart:ui',
        ) as Map;
    check(
      sameJson(uiEdge(value)['resolution'], {
        'kind': 'builtin',
        'identity': 'dart:ui',
      }),
      'Normalized embedder mapping',
    );
    check(
      value['payload']['analysis_complete'] == true,
      'Dot-segment analysis incomplete',
    );

    embedder.deleteSync();
    value = await invoke(2);
    check(
      value['payload']['analysis_complete'] == false,
      'Missing embedder accepted',
    );
    check(!embedder.existsSync(), 'Missing embedder repaired');
    check(
      (value['payload']['tool_errors'] as List).any(
        (e) => e['code'] == 'DART_ANALYSIS_FAILED',
      ),
      'Missing analysis error',
    );
    check(
      (value['payload']['input_identity']['inputs'] as List).any(
        (i) =>
            i['presence'] == 'absent' &&
            i['location']['canonical_file_uri'] == embedder.uri.toString(),
      ),
      'Missing embedder absence evidence',
    );

    embedder.writeAsBytesSync(embedderBytes);
    final uiSource = File(
      p.join(sdk.path, 'bin/cache/pkg/sky_engine/lib/ui/ui.dart'),
    );
    uiSource.deleteSync();
    value = await invoke(2);
    check(
      sameJson(uiEdge(value)['resolution'], {'kind': 'unresolved'}),
      'Missing SDK source resolved',
    );
    check(!uiSource.existsSync(), 'Missing SDK source repaired');
    checkViolation(value);

    final metadata = jsonDecode(manifest.readAsStringSync()) as Map;
    metadata['channel'] = 'beta';
    manifest.deleteSync();
    manifest.writeAsStringSync(jsonEncode(metadata));
    value = await invoke(2);
    check(
      value['tool_versions']['dart_sdk'] == null,
      'Beta SDK version accepted',
    );
    check(
      (value['payload']['tool_errors'] as List).any(
        (e) => e['code'] == 'DART_SDK_UNAVAILABLE',
      ),
      'Missing SDK error',
    );
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln(
    '$count real Flutter AOT checks passed; no launcher execution '
    'or project writes; syscall tracing=$trace',
  );
}
