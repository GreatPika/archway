// Real relocated AOT Dart checks; not clean-platform certification.
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

String dartExecutable(String sdk) =>
    p.join(sdk, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');

Future<NativeProcessResult> checked(
  List<String> command, {
  required int seconds,
  String? cwd,
}) async {
  final result = await runNativeProcess(
    command,
    timeout: Duration(seconds: seconds),
    workingDirectory: cwd,
  );
  check(
    result.exitCode == 0,
    '$command: ${result.exitCode}\n${utf8.decode(result.stdout)}\n${utf8.decode(result.stderr)}',
  );
  return result;
}

// Preserve SDK links without following them into a second copy of their target.
void copyTree(Directory source, Directory destination) {
  destination.createSync();
  for (final entity in source.listSync(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      copyTree(entity, Directory(target));
    } else if (entity is Link) {
      Link(target).createSync(entity.targetSync());
    } else {
      File(entity.path).copySync(target);
    }
  }
}

// Preparation-only native executable, never a script masquerading as Dart.
Future<void> compileTripwire(
  String sdk,
  String destination,
  File marker, {
  String? delegate,
}) async {
  String literal(String value) =>
      "utf8.decode(base64Decode('${base64Encode(utf8.encode(value))}'))";
  final temporary = Directory.systemTemp.createTempSync('archway-tripwire-');
  try {
    final program = File(p.join(temporary.path, 'tripwire.dart'));
    program.writeAsStringSync('''import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  File(${literal(marker.path)}).writeAsStringSync('query\\n', mode: FileMode.append);
  ${delegate == null ? 'exitCode = 99;' : '''final result = Process.runSync(${literal(delegate)}, args);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exitCode = result.exitCode;'''}
}
''');
    File(destination).parent.createSync(recursive: true);
    await checked([
      dartExecutable(sdk),
      '--suppress-analytics',
      'compile',
      'exe',
      program.path,
      '-o',
      destination,
    ], seconds: 90);
    check(
      File(destination).existsSync(),
      'Compiler did not create $destination',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

Future<void> main(List<String> arguments) async {
  final args = [...arguments];
  final existing = args.remove('--existing-installation');
  if (args.length != 2 || args.any((arg) => arg.startsWith('--'))) {
    stderr.writeln(
      'Usage: dart run test/dart_check_process_smoke.dart '
      '<executable> <sdk> [--existing-installation]',
    );
    exitCode = 64;
    return;
  }
  final executable = File(args[0]).resolveSymbolicLinksSync();
  final sdk = Directory(args[1]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-dart-process-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final install = Directory(p.join(base.path, 'installation café'))
      ..createSync();
    final binary = existing
        ? File(executable)
        : stageInstallation(File(executable), install);
    final root = Directory(p.join(base.path, 'prepared project'));
    File at(String name) => File(p.join(root.path, name));
    for (final name in ['lib/app', 'lib/core', '.dart_tool']) {
      Directory(p.join(root.path, name)).createSync(recursive: true);
    }
    at('lib/app/main.dart')
        .writeAsStringSync("import '../core/private.dart';\n");
    at('lib/core/private.dart').writeAsStringSync('class Thing {}\n');
    at('lib/app/main.ts').writeAsStringSync("import '../core/private';\n");
    at('lib/core/private.ts').writeAsStringSync('export const thing = 1;\n');
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
    final policy = at('architecture.yaml')
      ..writeAsStringSync('''version: 1
projects:
  - {id: dart, adapter: dart, package_roots: [./]}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''');
    String path(List<String> dirs) => dirs.join(Platform.isWindows ? ';' : ':');
    final realPath = path([p.join(sdk, 'bin')]);
    Future<Map> invoke(int expected, String runtimePath) async {
      final result = await runNativeProcess(
        [binary.path, '--root', root.path, 'check'],
        workingDirectory: base.path,
        environment: {...Platform.environment, 'PATH': runtimePath},
        timeout: const Duration(seconds: 45),
      );
      check(
        result.exitCode == expected,
        'Exit ${result.exitCode}, expected $expected: ${utf8.decode(result.stdout)}; ${utf8.decode(result.stderr)}',
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
      count++;
      return value;
    }

    var value = await invoke(1, realPath);
    check(value['status'] == 'negative', 'Dart result must be negative');
    check(
      value['payload']['analysis_complete'] == true,
      'Dart analysis incomplete',
    );
    check(
      sameJson(value['payload']['observed'], {
        'files': 2,
        'analyzed_files': 2,
        'edges': 1,
      }),
      'Dart observation mismatch',
    );
    check(
      sameJson(
        {
          for (final edge in value['payload']['facts']['edges'])
            edge['project_id']: [
              edge['resolution']['kind'],
              edge['resolution']['path'],
            ],
        },
        {
          'dart': ['local', 'lib/core/private.dart'],
        },
      ),
      'Dart edge mismatch',
    );
    check(
      value['tool_versions']['dart_sdk'] == '3.13.3',
      'Dart version mismatch',
    );
    check(
      value['tool_versions']['typescript'] == null &&
          value['tool_versions']['typescript_adapter'] == null &&
          value['tool_versions']['node'] == null,
      'Removed runtimes must remain null',
    );

    final runtime = Directory(p.join(base.path, 'runtime boundary fixture'));
    Directory(p.join(runtime.path, 'bin')).createSync(recursive: true);
    File(p.join(sdk, 'version')).copySync(p.join(runtime.path, 'version'));
    copyTree(
      Directory(p.join(sdk, 'lib')),
      Directory(p.join(runtime.path, 'lib')),
    );
    final counter = File(p.join(base.path, 'version queries'))
      ..writeAsStringSync('');
    await compileTripwire(
      sdk,
      dartExecutable(runtime.path),
      counter,
      delegate: dartExecutable(sdk),
    );
    final original = policy.readAsStringSync();
    policy.writeAsStringSync(
      original.replaceFirst(
        'scope: [lib/]',
        '  - {id: dart_other, adapter: dart, package_roots: [./]}\nscope: [lib/]',
      ),
    );
    final runtimePath = path([p.join(runtime.path, 'bin')]);
    value = await invoke(2, runtimePath);
    check(
      sameJson(counter.readAsLinesSync(), ['query']),
      'Expected one preflight: ${counter.readAsStringSync()}',
    );
    final dartRows = (value['payload']['coverage']['files'] as List).where(
      (row) => (row['path'] as String).endsWith('.dart'),
    );
    check(
      dartRows.every(
        (row) =>
            row['assignment'] == 'ambiguous' && row['candidates'].length == 2,
      ),
      'Overlapping Dart assignments',
    );
    policy.writeAsStringSync(original);

    File(p.join(runtime.path, 'version')).writeAsStringSync('0.0.0\n');
    final queriesBefore = counter.readAsBytesSync();
    value = await invoke(2, runtimePath);
    check(
      value['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE',
      'Wrong SDK metadata accepted',
    );
    check(
      sameJson(counter.readAsBytesSync(), queriesBefore),
      'Wrong SDK executable was queried',
    );

    value = await invoke(2, '/no-runtime-here');
    check(value['status'] == 'incomplete', 'Missing Dart must be incomplete');
    check(
      value['tool_versions']['dart_sdk'] == null,
      'Missing SDK version must be null',
    );
    check(
      value['payload']['facts']['edges'].isEmpty,
      'Missing SDK fabricated facts',
    );
    check(
      value['payload']['tool_errors'][0]['code'] == 'DART_SDK_UNAVAILABLE',
      'Missing Dart error',
    );

    final marker = at('executed-project-code');
    final wrapper = at(p.basename(dartExecutable(sdk)));
    await compileTripwire(sdk, wrapper.path, marker);
    final calibration = await runNativeProcess([
      wrapper.path,
      '--version',
    ], timeout: const Duration(seconds: 5));
    check(
      calibration.exitCode == 99 &&
          marker.existsSync() &&
          marker.readAsStringSync() == 'query\n',
      'Project-runtime tripwire did not record its calibration execution',
    );
    marker.deleteSync();
    final aliases = Directory(p.join(base.path, 'aliases'))..createSync();
    Link(p.join(aliases.path, p.basename(wrapper.path)))
        .createSync(wrapper.path);
    await invoke(2, path([aliases.path, root.path]));
    check(!marker.existsSync(), 'Project-local runtime executed through alias');

    Directory(p.join(root.path, 'lib/ignored')).createSync();
    at('lib/ignored/bad[1].dart').writeAsStringSync('class Odd {}');
    at('lib/app/main.dart')
        .writeAsStringSync("import '../ignored/bad[1].dart';");
    policy.writeAsStringSync(
      original.replaceFirst('exclude: []', 'exclude: [lib/ignored/]'),
    );
    value = await invoke(2, realPath);
    final edge = (value['payload']['facts']['edges'] as List).firstWhere(
      (edge) => edge['project_id'] == 'dart',
    );
    check(
      sameJson(edge['resolution'], {'kind': 'unresolved'}),
      'Unsupported spelling became a Plan operand',
    );
    check(
      (value['payload']['input_identity']['inputs'] as List).any(
        (input) => input['location']['path'] == 'lib/ignored/bad[1].dart',
      ),
      'Physical input evidence lost',
    );
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln('$count real Dart AOT process checks passed');
}
