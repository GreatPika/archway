// Bounded installed-CLI checks for real nonregular Dart analyzer resources.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/native_file_fixtures.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run test/dart_resource_process_smoke.dart <executable> <dart-sdk>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(arguments[0]).resolveSymbolicLinksSync();
  final sdk = Directory(arguments[1]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-resource-types-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final root = Directory(p.join(base.path, 'project'))..createSync();
    File at(String name) => File(p.join(root.path, name));
    Directory(p.join(root.path, 'lib')).createSync();
    Directory(p.join(root.path, '.dart_tool')).createSync();
    at('lib/main.dart').writeAsStringSync('class App {}');
    at('pubspec.yaml').writeAsStringSync(
      'name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n',
    );
    at('.dart_tool/package_config.json').writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'fixture',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
        ],
      }),
    );
    at('architecture.yaml').writeAsStringSync('''version: 1
projects: [{id: dart, adapter: dart, package_roots: [./]}]
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [lib/], allows: [], public: []}
''');
    Future<Map> invoke(String runtime, int expected) async {
      final child = await Process.start(
        executable,
        ['--root', root.path, 'check'],
        workingDirectory: base.path,
        environment: {...Platform.environment, 'PATH': p.join(runtime, 'bin')},
        includeParentEnvironment: false,
      );
      final output = <int>[], errors = <int>[];
      final completion = Future.wait<Object?>([
        child.exitCode,
        child.stdout.forEach(output.addAll),
        child.stderr.forEach(errors.addAll),
        child.stdin.close(),
      ]);
      List<Object?> result;
      try {
        result = await completion.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await completion.timeout(const Duration(seconds: 2));
        throw TimeoutException(
          'Resource check exceeded 5 seconds; stdout=$output; stderr=$errors',
        );
      }
      _check(
        result.first == expected,
        '$runtime: exit ${result.first}; stdout=$output; stderr=$errors',
      );
      _check(errors.isEmpty, '$runtime: unexpected stderr=$errors');
      _check(
        output.where((byte) => byte == 10).length == 1,
        '$runtime: expected one JSON line',
      );
      final value = jsonDecode(utf8.decode(output)) as Map;
      final violations = schema.errors(value);
      _check(
        violations.isEmpty,
        '$runtime: invalid public schema: $violations',
      );
      _check(
        value['exit_code'] == expected,
        '$runtime: envelope exit mismatch',
      );
      count++;
      return value;
    }

    _check(
      (await invoke(sdk, 0))['payload']['analysis_complete'] == true,
      'Prepared SDK must produce complete analysis',
    );
    final damaged = Directory(p.join(base.path, 'damaged SDK'))..createSync();
    Directory(p.join(damaged.path, 'bin')).createSync();
    String dartExecutable(String directory) =>
        p.join(directory, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');
    File(dartExecutable(sdk)).copySync(dartExecutable(damaged.path));
    final version = p.join(damaged.path, 'version');
    createNonregularResource(version);
    try {
      final value = await invoke(damaged.path, 2);
      _check(
        value['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE',
        'Nonregular SDK version must reject the runtime',
      );
    } finally {
      removeNonregularResource(version);
    }
    File(p.join(sdk, 'version')).copySync(version);
    Directory(p.join(damaged.path, 'lib')).createSync();
    final libraries = p.join(damaged.path, 'lib', 'libraries.json');
    createNonregularResource(libraries);
    try {
      _check(
        (await invoke(damaged.path, 2))['payload']['tool_errors'][0]['code'] ==
            'DART_SDK_UNAVAILABLE',
        'Nonregular SDK libraries must reject the runtime',
      );
      final options = at('analysis_options.yaml');
      createNonregularResource(options.path);
      try {
        _check(
          (await invoke(sdk, 2))['payload']['analysis_complete'] == false,
          'Nonregular analyzer options cannot become a complete analysis',
        );
      } finally {
        removeNonregularResource(options.path);
      }
      _check(
        (await invoke(sdk, 0))['payload']['analysis_complete'] == true,
        'Analysis must recover after removing nonregular options',
      );
      final actualOptions = at('options.actual.yaml')
        ..writeAsStringSync('analyzer:\n  language:\n    strict-casts: true\n');
      Link(options.path).createSync(actualOptions.path);
      final value = await invoke(sdk, 0);
      _check(
        (value['payload']['input_identity']['aliases'] as List).any(
          (alias) => sameJson(alias, {
            'observed_file_uri': options.uri.toString(),
            'canonical_file_uri': actualOptions.uri.toString(),
          }),
        ),
        'Options alias must retain observed and canonical file identities',
      );
    } finally {
      removeNonregularResource(libraries);
    }
  } finally {
    base.deleteSync(recursive: true);
  }
  final mechanism = Platform.isWindows
      ? 'nonregular directories (POSIX filesystem FIFO inapplicable)'
      : 'POSIX FIFO';
  stdout.writeln(
    '$count bounded real-process resource-type checks passed; mechanism=$mechanism',
  );
}

void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}
