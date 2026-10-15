// Real native PATH/preflight/installed-compiler checks through CLI transport.
// Trusted fixture runtimes never supply compiler evidence; Node forwards actual
// compiler requests. Linux host results are not target certification.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import 'dart_check_process_smoke.dart' show compileTripwire, dartExecutable;
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// Preparation-only native version faults, with real Node compiler forwarding.
Future<File> compileNodeFixture(
  String sdk,
  File destination,
  String node,
) async {
  final config = File(p.join(destination.parent.path, 'preflight.json'));
  String literal(String value) =>
      "utf8.decode(base64Decode('${base64Encode(utf8.encode(value))}'))";
  final temporary = Directory.systemTemp.createTempSync(
    'archway-node-fixture-',
  );
  try {
    final program = File(p.join(temporary.path, 'fixture.dart'))
      ..writeAsStringSync('''import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final config = jsonDecode(File(${literal(config.path)}).readAsStringSync());
  if (args.length == 1 && args.first == '--version') {
    if (config['marker'] != null) {
      File(config['marker']).writeAsStringSync('queried');
    }
    stdout.write(config['version']);
    stderr.add(List<int>.filled(config['stderr_bytes'], 120));
    await stdout.flush();
    await stderr.flush();
    if (config['delay_ms'] > 0) {
      await Future<void>.delayed(Duration(milliseconds: config['delay_ms']));
    }
    exitCode = config['exit_code'];
  } else {
    final child = await Process.start(${literal(node)}, args);
    await Future.wait([
      stdin.pipe(child.stdin),
      child.stdout.pipe(stdout),
      child.stderr.pipe(stderr),
    ]);
    exitCode = await child.exitCode;
  }
}
''');
    final result = await runNativeProcess([
      dartExecutable(sdk),
      '--suppress-analytics',
      'compile',
      'exe',
      program.path,
      '-o',
      destination.path,
    ], timeout: const Duration(seconds: 90));
    check(
      result.exitCode == 0 && destination.existsSync(),
      'Preflight fixture compile failed: ${utf8.decode(result.stdout)} ${utf8.decode(result.stderr)}',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
  return config;
}

Future<void> main(List<String> args) async {
  if (args.length != 4 || args.any((arg) => arg.startsWith('--'))) {
    stderr.writeln(
      'Usage: dart run test/runtime_preflight_process_smoke.dart '
      '<executable> <node> <wrong-node> <sdk>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(args[0]).resolveSymbolicLinksSync();
  final node = File(args[1]).resolveSymbolicLinksSync();
  final wrongNode = File(args[2]).resolveSymbolicLinksSync();
  final sdk = Directory(args[3]).resolveSymbolicLinksSync();
  final separator = Platform.isWindows ? ';' : ':';
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-preflight-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final install = Directory(p.join(base.path, 'installation'))..createSync();
    final archway = stageInstallation(File(executable), install);
    final root = Directory(p.join(base.path, 'project'));
    File at(String path) => File(p.join(root.path, path));
    for (final path in ['lib/app', 'lib/core', '.dart_tool']) {
      Directory(p.join(root.path, path)).createSync(recursive: true);
    }
    at('lib/app/main.dart')
        .writeAsStringSync("import '../core/private.dart';\n");
    at('lib/core/private.dart').writeAsStringSync('class Value {}\n');
    at('tsconfig.json').writeAsStringSync('{"files":[]}');
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
projects:
  - {id: dart, adapter: dart, package_roots: [./]}
  - {id: web, adapter: typescript, tsconfig: tsconfig.json}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''');
    final command = [archway.path, '--root', root.path, 'check'];
    void validate(Map value) {
      final errors = schema.errors(value);
      check(errors.isEmpty, 'Invalid public schema: $errors');
    }

    Future<Map> invoke(
      String path, {
      String code = 'NODE_UNAVAILABLE',
      Map<String, String> env = const {},
    }) async {
      final result = await runNativeProcess(
        command,
        workingDirectory: base.path,
        environment: {
          ...Platform.environment,
          'PATH': '$path$separator${p.join(sdk, 'bin')}',
          ...env,
        },
        timeout: const Duration(seconds: 15),
      );
      check(
        result.exitCode == 2 && result.stderr.isEmpty,
        'Unexpected process result: $result',
      );
      check(
        result.stdout.isNotEmpty &&
            result.stdout.last == 10 &&
            result.stdout.where((byte) => byte == 10).length == 1,
        'Expected one JSON line',
      );
      final value = jsonDecode(utf8.decode(result.stdout)) as Map;
      validate(value);
      check(value['exit_code'] == 2, 'Envelope exit mismatch');
      check(
        (value['payload']['tool_errors'] as List).any((e) => e['code'] == code),
        'Expected $code: ${value['payload']['tool_errors']}',
      );
      check(
        value['tool_versions']['dart_sdk'] == '3.13.3',
        'Dart version lost',
      );
      check(
        value['payload']['facts']['edges'][0]['project_id'] == 'dart',
        'Independent Dart fact lost',
      );
      check(
        value['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED',
        'Independent Dart violation lost',
      );
      count++;
      return value;
    }

    String message(Map value) =>
        value['payload']['tool_errors'][0]['message'] as String;

    final wrongVersion = await runNativeProcess([
      wrongNode,
      '--version',
    ], timeout: const Duration(seconds: 15));
    check(
      wrongVersion.exitCode == 0 &&
          utf8.decode(wrongVersion.stdout).trim() != 'v24.21.0',
      'Wrong-version Node must be a real incompatible runtime',
    );
    var value = await invoke(p.dirname(wrongNode));
    check(
      value['tool_versions']['node'] == null,
      'Wrong Node version retained',
    );
    check(
      message(value).contains('24.21.0 required'),
      'Missing pinned-version diagnostic',
    );
    await invoke('/nonexistent/runtime');

    final marker = File(p.join(base.path, 'project-code-executed'));
    final runtimeName = Platform.isWindows ? 'node.exe' : 'node';
    final malicious = at(runtimeName);
    await compileTripwire(sdk, malicious.path, marker);
    // Keep raw dot segments and empty/relative PATH entries unnormalized.
    for (final path in [
      root.path,
      '${root.path}/nested/..',
      '.',
      '',
      '$separator${root.path}',
      '${root.path}/../project',
    ]) {
      await invoke(path);
      check(
        !marker.existsSync(),
        'Repository runtime or relative PATH was executed',
      );
    }
    final alias = Directory(p.join(base.path, 'alias-runtime'))..createSync();
    Link(p.join(alias.path, runtimeName)).createSync(malicious.path);
    await invoke(alias.path);
    check(!marker.existsSync(), 'Repository runtime alias executed');
    malicious.copySync(p.join(base.path, runtimeName));
    await invoke(base.path);
    check(!marker.existsSync(), 'Invocation cwd runtime executed');

    final runtime = Directory(p.join(base.path, 'trusted runtime'))
      ..createSync();
    final config = await compileNodeFixture(
      sdk,
      File(p.join(runtime.path, runtimeName)),
      node,
    );
    void preflight({
      String version = 'v24.21.0\n',
      int stderrBytes = 0,
      int delayMs = 0,
      int exitCode = 0,
      String? marker,
    }) {
      config.writeAsStringSync(
        jsonEncode({
          'version': version,
          'stderr_bytes': stderrBytes,
          'delay_ms': delayMs,
          'exit_code': exitCode,
          'marker': marker,
        }),
      );
    }

    preflight(marker: marker.path, version: '');
    final calibration = await runNativeProcess([
      p.join(runtime.path, runtimeName),
      '--version',
    ], timeout: const Duration(seconds: 5));
    check(
      calibration.exitCode == 0 &&
          marker.existsSync() &&
          marker.readAsStringSync() == 'queried',
      'Configured Node fixture did not record its calibration query',
    );
    marker.deleteSync();
    for (final args in [
      ['--help'],
      ['--version'],
      ['--root', root.path, 'validate'],
    ]) {
      final result = await runNativeProcess(
        [archway.path, ...args],
        workingDirectory: base.path,
        environment: {...Platform.environment, 'PATH': runtime.path},
        timeout: const Duration(seconds: 5),
      );
      check(
        result.exitCode == 0 && result.stderr.isEmpty,
        'Non-check failed: $result',
      );
      check(!marker.existsSync(), 'Non-check command queried a runtime');
      if (args.last == 'validate')
        validate(jsonDecode(utf8.decode(result.stdout)) as Map);
      count++;
    }
    // Exactly 64 KiB combined output passes preflight, then real TypeScript
    // diagnoses empty files; the first byte over fails in the adapter.
    for (final extra in [0, 1]) {
      preflight(stderrBytes: 65536 - utf8.encode('v24.21.0\n').length + extra);
      value = await invoke(
        runtime.path,
        code: extra == 0 ? 'TYPESCRIPT_CONFIG_ERROR' : 'NODE_UNAVAILABLE',
      );
      check(
        value['tool_versions']['node'] == (extra == 0 ? '24.21.0' : null),
        'Combined limit version mismatch',
      );
      if (extra != 0)
        check(
          message(value).contains('limit exceeded'),
          'Missing limit diagnostic',
        );
    }
    preflight(version: '', delayMs: 60000);
    final timer = Stopwatch()..start();
    value = await invoke(runtime.path);
    timer.stop();
    check(
      timer.elapsedMicroseconds >= 4900000 &&
          timer.elapsedMicroseconds < 9000000,
      'Preflight deadline duration: ${timer.elapsed}',
    );
    check(
      message(value).contains('deadline exceeded'),
      'Missing deadline diagnostic',
    );
    preflight(exitCode: 9);
    check(
      message(await invoke(runtime.path)).contains('code 9'),
      'Missing exit diagnostic',
    );

    final loader = at('loader.cjs')
      ..writeAsStringSync(
        'require("node:fs").writeFileSync(${jsonEncode(marker.path)},"executed");',
      );
    value = await invoke(
      p.dirname(node),
      code: 'TYPESCRIPT_CONFIG_ERROR',
      env: {
        'NODE_OPTIONS': '--require=${loader.path}',
        'NODE_PATH': root.path,
        'LD_LIBRARY_PATH': root.path,
        'DYLD_LIBRARY_PATH': root.path,
      },
    );
    check(
      value['tool_versions']['node'] == '24.21.0',
      'Pinned Node version lost',
    );
    check(!marker.existsSync(), 'Environment preload executed');

    // Project source, scripts, compiler plugins and preloads are data. A
    // successful syscall trace remains a separate release gate.
    final source = at('lib/main.ts')
      ..writeAsStringSync(
        'require("node:fs").writeFileSync(${jsonEncode(marker.path)},"executed");',
      );
    at('package.json').writeAsStringSync(
      jsonEncode({
        'scripts': {
          'preinstall': '$node ${loader.path}',
          'build': '$node ${loader.path}',
        },
      }),
    );
    at('plugin.cjs').writeAsBytesSync(loader.readAsBytesSync());
    at('tsconfig.json').writeAsStringSync(
      jsonEncode({
        'files': ['lib/main.ts'],
        'compilerOptions': {
          'plugins': [
            {'name': './plugin.cjs'},
          ],
        },
      }),
    );
    final traced = await runNativeProcess(
      command,
      workingDirectory: base.path,
      environment: {
        ...Platform.environment,
        'PATH': '${p.dirname(node)}$separator${p.join(sdk, 'bin')}',
        'NODE_OPTIONS': '--require=${loader.path}',
      },
      timeout: const Duration(seconds: 15),
    );
    check(
      traced.exitCode == 2 && traced.stderr.isEmpty,
      'Source tripwire result: $traced',
    );
    validate(jsonDecode(utf8.decode(traced.stdout)) as Map);
    check(!marker.existsSync(), 'Project code was executed');
    count++;
    source.deleteSync();
    at('tsconfig.json').writeAsStringSync('{"files":[]}');

    final compiler = File(
      p.join(
        install.path,
        'assets/typescript/vendor/typescript/lib/typescript.js',
      ),
    );
    final original = compiler.readAsBytesSync();
    compiler.writeAsStringSync('module.exports = {version:"0.0.0"};');
    value = await invoke(p.dirname(node), code: 'TYPESCRIPT_VERSION_MISMATCH');
    check(
      value['tool_versions']['typescript'] == null,
      'Mismatched compiler version retained',
    );
    compiler.writeAsStringSync(
      'throw new Error("cannot load installed compiler");',
    );
    value = await invoke(p.dirname(node), code: 'TYPESCRIPT_LOAD_FAILED');
    check(
      value['tool_versions']['typescript'] == null,
      'Unloadable compiler version retained',
    );
    compiler.writeAsBytesSync(original);
    File(p.join(install.path, 'assets/typescript/framing.cjs')).deleteSync();
    await invoke(p.dirname(node), code: 'TYPESCRIPT_ASSETS_UNAVAILABLE');
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln('$count real preflight/retention/schema checks passed.');
}
