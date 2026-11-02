// Exercise the real SDK-installed executable, not `dart run` or a mock CLI.
// Usage: dart run tool/installed_package_smoke.dart /absolute/path/to/archway
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

import '../test/support/native_process_support.dart';
import '../test/support/windows_command.dart';
import '../test/support/windows_process.dart' show windowsCommandLine;

// Pinned SDK 3.13.5 fixture contract, not a product launcher or general parser.
String sdkWindowsBundleTarget(String script) {
  final match = RegExp(
    r'^@ECHO OFF\r?\nREM target_file_path_marker\r?\n"([^"\r\n]+)" %\*\r?\nEXIT /B %ERRORLEVEL%\r?\n$',
  ).firstMatch(script);
  if (match == null ||
      match.end != script.length ||
      !p.windows.isAbsolute(match[1]!)) {
    throw const FormatException('Unrecognized SDK Windows launcher');
  }
  return match[1]!;
}

// This quotes only our bounded fixture argv; it deliberately rejects shell text.
WindowsRawCommandLine sdkWindowsBatchCommand(
  List<String> arguments,
  String cmd,
) {
  if (arguments.isEmpty ||
      [
        cmd,
        ...arguments,
      ].any((arg) => RegExp(r'["%!&|<>^\r\n\x00]').hasMatch(arg))) {
    throw ArgumentError('Unsupported shell syntax in owned batch fixture argv');
  }
  return WindowsRawCommandLine(
    applicationName: cmd,
    commandLine:
        '"$cmd" /d /s /v:off /c "${arguments.map((arg) => '"$arg"').join(' ')}"',
    logicalArguments: arguments,
  );
}

Future<void> main(List<String> args) async {
  if (args.length == 4 && args[0] == '--install-git' && args[2] == '--ref') {
    final descriptor = jsonEncode({
      'git': {'url': p.absolute(args[1]), 'ref': args[3]},
    });
    final install = await Process.run(Platform.resolvedExecutable, [
      'install',
      'archway@$descriptor',
    ]);
    stdout.write(install.stdout);
    stderr.write(install.stderr);
    if (install.exitCode != 0) throw StateError('dart install failed');
    final matches = RegExp(
      r'^Installed: (.+)$',
      multiLine: true,
    ).allMatches(install.stdout as String).toList();
    if (matches.length != 1)
      throw StateError('Expected one SDK installed executable');
    final binary = matches.single[1]!.trim();
    try {
      var bundleExecutable = binary;
      if (Platform.isWindows) {
        final launcher = File(binary).readAsStringSync();
        final target = sdkWindowsBundleTarget(launcher);
        final expected = p.join(
          File(binary).parent.parent.path,
          'app-bundles',
          'archway',
          'git',
          args[3],
          'bundle',
          'bin',
          'archway.exe',
        );
        if (!p.windows.equals(target, expected) || !File(target).existsSync()) {
          throw StateError(
            'SDK launcher target differs from installed Git revision',
          );
        }
        bundleExecutable = File(target).resolveSymbolicLinksSync();
        stdout.writeln(
          jsonEncode({
            'sdk_windows_launcher': {
              'path': binary,
              'contents': launcher,
              'sha256': sha256
                  .convert(File(binary).readAsBytesSync())
                  .toString(),
              'verified_bundle_target': bundleExecutable,
            },
          }),
        );
      }
      await probe([binary]);
      stdout.writeln(
        'Actual SDK launcher probes passed; separate bundle fault suites follow.',
      );
      final repository = File.fromUri(Platform.script).parent.parent.path;
      final sdk = p.dirname(p.dirname(Platform.resolvedExecutable));
      for (final suite in [
        'cli',
        'plan_query',
        'catalogue_export',
        'native_asset',
        'native_abi',
        'native_fault',
        'physical_path',
        'dart_check',
        'dart_resource',
      ]) {
        final result = await runNativeProcess(
          [
            Platform.resolvedExecutable,
            'run',
            p.join(repository, 'test', '${suite}_process_smoke.dart'),
            bundleExecutable,
            if ([
              'physical_path',
              'dart_check',
              'dart_resource',
            ].contains(suite))
              sdk,
          ],
          timeout: const Duration(minutes: 5),
          workingDirectory: repository,
        );
        stdout.add(result.stdout);
        stderr.add(result.stderr);
        if (result.exitCode != 0)
          throw StateError('$suite failed: ${result.exitCode}');
      }
    } finally {
      final uninstall = await Process.run(Platform.resolvedExecutable, [
        'uninstall',
        'archway',
      ]);
      stdout.write(uninstall.stdout);
      stderr.write(uninstall.stderr);
      if (uninstall.exitCode != 0 || File(binary).existsSync()) {
        throw StateError(
          'dart uninstall did not remove the installed executable',
        );
      }
    }
    return;
  }
  await probe(args);
}

Future<void> probe(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the actual dart-install executable path.');
  }
  final binary = File(args.single).resolveSymbolicLinksSync();
  final sdkBin = p.dirname(Platform.resolvedExecutable);
  WindowsRawCommandLine? launcherCommand(List<String> arguments) =>
      Platform.isWindows && p.extension(binary).toLowerCase() == '.bat'
      ? sdkWindowsBatchCommand(
          arguments,
          p.join(Platform.environment['SystemRoot']!, 'System32', 'cmd.exe'),
        )
      : null;
  final base = await Directory.systemTemp.createTemp('archway-installed-café-');
  var count = 0;
  try {
    final cwd = Directory(p.join(base.path, 'чужая папка'))..createSync();
    final project = Directory(p.join(base.path, 'prepared project'))
      ..createSync();
    final environment = {
      for (final entry in Platform.environment.entries)
        if (entry.key.toUpperCase() != 'PATH') entry.key: entry.value,
      // No Node, C compiler, shell or project executable on PATH.
      'PATH': sdkBin,
    };
    Future<Map<String, dynamic>> run(List<String> command, int expected) async {
      final arguments = [binary, '--root', project.path, ...command];
      final raw = launcherCommand(arguments);
      if (raw != null) {
        stdout.writeln(jsonEncode({'sdk_batch_execution': raw.toJson()}));
        if (count == 1) {
          // Paired diagnostic on non-mutating existing-file init conflict.
          // Do not certify the BAT by silently running its EXE instead.
          final control = <String, Object?>{
            'application_name': arguments.first,
            'command_line': windowsCommandLine(arguments),
            'arguments': arguments,
          };
          try {
            final direct = await runNativeProcess(
              arguments,
              workingDirectory: cwd.path,
              environment: environment,
              timeout: const Duration(seconds: 45),
            );
            control.addAll({
              'exit': direct.exitCode,
              'stdout': utf8.decode(direct.stdout, allowMalformed: true),
              'stderr': utf8.decode(direct.stderr, allowMalformed: true),
            });
          } on OSError catch (error) {
            // Only the known non-PE batch spawn refusal is diagnostic.
            // Timeout, ownership and cleanup failures must still fail the gate.
            if (error.message != 'CreateProcessW' || error.errorCode != 193)
              rethrow;
            control['spawn_error'] = {
              'message': error.message,
              'code': error.errorCode,
            };
          }
          stdout.writeln(jsonEncode({'native_batch_control': control}));
        }
      }
      final result = await runNativeProcess(
        arguments,
        windowsCommand: raw,
        workingDirectory: cwd.path,
        environment: environment,
        timeout: const Duration(seconds: 45),
      );
      if (result.exitCode != expected || result.stderr.isNotEmpty) {
        throw StateError(
          '$command: exit ${result.exitCode}; '
          '${utf8.decode(result.stderr)} ${utf8.decode(result.stdout)}',
        );
      }
      final text = utf8.decode(result.stdout);
      if (!text.endsWith('\n') || '\n'.allMatches(text).length != 1) {
        throw StateError('Expected exactly one JSON output line: $command');
      }
      final resultJson = jsonDecode(text) as Map<String, dynamic>;
      if (resultJson['exit_code'] != expected ||
          resultJson['schema_version'] != 1) {
        throw StateError('Incorrect public envelope: $command');
      }
      count++;
      return resultJson;
    }

    final init = await run(['init'], 0);
    if (init['payload']['outcome'] != 'created' ||
        init['payload']['template'] != 'dart') {
      throw StateError('Default Dart init did not create its files.');
    }
    await run(['init'], 2); // Existing user files must remain untouched.
    File file(String relative) => File(p.join(project.path, relative));
    file('architecture.yaml').writeAsStringSync('''
version: 1
projects:
  - {id: app, adapter: dart, package_roots: [./]}
scope: [lib/]
exclude: [lib/core/alias.dart]
nodes:
  - {id: app, responsibility: Application, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''');
    Directory(p.join(project.path, 'lib/app')).createSync(recursive: true);
    Directory(p.join(project.path, 'lib/core')).createSync(recursive: true);
    file('lib/core/private.dart').writeAsStringSync('class Thing {}\n');
    final alias = Link(p.join(project.path, 'lib/core/alias.dart'));
    // Creating Windows symlinks requires Developer Mode or the relevant right.
    // This is an explicit platform acceptance prerequisite, never a silent skip.
    alias.createSync('private.dart');
    file('lib/app/main.dart').writeAsStringSync(
      "import '../core/alias.dart';\nThing make() => Thing();\n",
    );
    file('lib/build.js')
        .writeAsStringSync('throw new Error("Never execute");\n');
    file('pubspec.yaml').writeAsStringSync(
      'name: fixture\nenvironment:\n  sdk: ">=3.13.5 <4.0.0"\n',
    );
    // Preparation is separate from inspection, using the actual package manager.
    final prep = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: project.path);
    if (prep.exitCode != 0)
      throw StateError('Fixture preparation: ${prep.stderr}');
    await run(['validate'], 0);
    await run(['owner', 'lib/app/main.dart'], 0);
    final check = await run(['check'], 1);
    final payload = check['payload'] as Map;
    if (payload['analysis_complete'] != true ||
        jsonEncode(payload['observed']) !=
            jsonEncode({'files': 2, 'analyzed_files': 2, 'edges': 1}) ||
        (payload['input_identity']['aliases'] as List).isEmpty ||
        (payload['violations'] as List).single['code'] !=
            'DEPENDENCY_NOT_ALLOWED') {
      throw StateError(
        'Installed linked Dart inspection lost evidence: $payload',
      );
    }
    for (final key in ['typescript_adapter', 'node', 'typescript']) {
      if (check['tool_versions'][key] != null)
        throw StateError('Unexpected $key');
    }
    final exportArguments = [
      binary,
      '--root',
      project.path,
      'export',
      '--format',
      'mermaid',
      '--out',
      'graph.mmd',
    ];
    final export = await runNativeProcess(
      exportArguments,
      windowsCommand: launcherCommand(exportArguments),
      workingDirectory: cwd.path,
      environment: environment,
      timeout: const Duration(seconds: 10),
    );
    if (export.exitCode != 0 ||
        export.stderr.isNotEmpty ||
        !file('graph.mmd').readAsStringSync().contains('flowchart')) {
      throw StateError('Installed Mermaid export failed: $export');
    }
    count++;
    stdout.writeln(
      '$count installed-package checks passed; Dart-only PATH, '
      'Unicode/spaced cwd, prepared linked Dart corpus, init/query/export.',
    );
  } finally {
    await base.delete(recursive: true);
  }
}
