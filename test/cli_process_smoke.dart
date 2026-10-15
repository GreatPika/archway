// Installed CLI transport and schema acceptance with runtime discovery disabled.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run test/cli_process_smoke.dart <executable>');
    exitCode = 64;
    return;
  }
  final executable = File(arguments.single).absolute.path;
  ContractSchema schema(String name) => ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/$name.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final public = schema('public-result');
  final export = schema('export-diagnostics');
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-process-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final cwd = Directory(p.join(base.path, 'unrelated cwd ü'))..createSync();
    Future<ProcessResult> run(
      List<String> args, {
      bool unprivileged = false,
    }) async {
      final process = await Process.start(
        unprivileged ? Platform.resolvedExecutable : executable,
        unprivileged
            ? [
                Platform.script
                    .resolve('support/linux_unprivileged_cli.dart')
                    .toFilePath(),
                executable,
                ...args,
              ]
            : args,
        workingDirectory: cwd.path,
        environment: {...Platform.environment, 'PATH': '/no-runtime-here'},
        includeParentEnvironment: false,
      );
      final output = <int>[], errors = <int>[];
      final completion = Future.wait<Object?>([
        process.exitCode,
        process.stdout.forEach(output.addAll),
        process.stderr.forEach(errors.addAll),
        process.stdin.close(),
      ]);
      List<Object?> result;
      try {
        result = await completion.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await completion.timeout(const Duration(seconds: 2));
        throw TimeoutException(
          'CLI timed out: $args; stdout=$output; stderr=$errors',
        );
      }
      return ProcessResult(process.pid, result.first as int, output, errors);
    }

    Future<Map> invoke(
      List<String> args,
      int expected, {
      bool exportMode = false,
      bool unprivileged = false,
    }) async {
      final result = await run(args, unprivileged: unprivileged);
      _check(
        result.exitCode == expected,
        '$args: exit ${result.exitCode}; stdout=${result.stdout}; stderr=${result.stderr}',
      );
      final content = (exportMode ? result.stderr : result.stdout) as List<int>;
      final other = (exportMode ? result.stdout : result.stderr) as List<int>;
      _check(other.isEmpty, '$args: unexpected other stream: $other');
      _check(
        content.isNotEmpty &&
            content.last == 10 &&
            content.where((byte) => byte == 10).length == 1 &&
            !(content.length >= 3 &&
                content[0] == 0xef &&
                content[1] == 0xbb &&
                content[2] == 0xbf),
        '$args: expected one newline-terminated JSON value without BOM',
      );
      final value = jsonDecode(utf8.decode(content)) as Map;
      final errors = (exportMode ? export : public).errors(value);
      _check(errors.isEmpty, '$args: $errors');
      _check(
        value['exit_code'] == result.exitCode,
        '$args: envelope exit mismatch',
      );
      count++;
      return value;
    }

    final policies = <String>{};
    for (final template in ['dart', 'typescript', 'mixed']) {
      final root = Directory(p.join(base.path, '$template root café'))
        ..createSync();
      final preview = await invoke([
        '--root',
        root.path,
        'init',
        '--template',
        template,
        '--dry-run',
      ], 0);
      _check(root.listSync().isEmpty, '$template: dry-run wrote files');
      final created = await invoke([
        'init',
        '--template=$template',
        '--root=${root.path}',
      ], 0);
      _check(
        created['payload']['outcome'] == 'created',
        '$template: init outcome',
      );
      final names =
          root.listSync().map((entry) => p.basename(entry.path)).toList()
            ..sort();
      _check(
        sameJson(names, ['ARCHITECTURE.md', 'architecture.yaml']),
        '$template: unexpected bootstrap files: $names',
      );
      for (final file in preview['payload']['planned_files']) {
        _check(
          sameJson(
            File(p.join(root.path, file['path'])).readAsBytesSync(),
            utf8.encode(file['content']),
          ),
          '$template: preview differs from written bytes',
        );
      }
      final validated = await invoke(['validate', '--root', root.path], 0);
      final policy = File(p.join(root.path, 'architecture.yaml'))
          .readAsBytesSync();
      _check(
        validated['policy_hash'] == 'sha256:${sha256.convert(policy)}',
        '$template: policy hash differs from exact bytes',
      );
      _check(
        sameJson(validated['payload'], {
          'policy_valid': true,
          'projects': 0,
          'nodes': 0,
        }),
        '$template: validation payload',
      );
      _check(
        sameJson(
          (validated['diagnostics'] as List).map((d) => d['code']).toList(),
          ['EMPTY_PLAN'],
        ),
        '$template: expected EMPTY_PLAN',
      );
      policies.add(
        utf8
            .decode(policy)
            .split('\n')
            .where((line) => !line.startsWith('#'))
            .join('\n'),
      );
      final conflict = await invoke([
        'init',
        '--root',
        root.path,
        '--template',
        template,
        '--dry-run',
      ], 2);
      _check(
        conflict['payload']['outcome'] == 'conflict',
        '$template: expected conflict',
      );
      _check(
        conflict['payload']['planned_files'].length == 2,
        '$template: conflict must retain both planned files',
      );
    }
    _check(policies.length == 1, 'Templates differ beyond policy comments');
    await invoke(['validate'], 2); // No parent/repository search from cwd.
    await invoke(['init', '--template', 'dart', '--policy', 'x'], 64);
    await invoke(['validate', '--policy', '../escape'], 64);
    await invoke(['not-a-command'], 64);
    await invoke(['export'], 64, exportMode: true);
    File(p.join(cwd.path, 'architecture.yaml')).writeAsStringSync('[');
    final invalid = await invoke(['validate'], 2);
    _check(
      invalid['status'] == 'invalid_policy' && invalid['policy_hash'] != null,
      'Malformed bytes must retain their policy hash',
    );
    if (Platform.isLinux) {
      _chmod(
        base.path,
        0x1ed,
      ); // 0755: uid 65534 may traverse the owned fixture.
      _chmod(cwd.path, 0x1ed);
      final denied = Directory(p.join(base.path, 'unreadable-root'))
        ..createSync();
      try {
        _chmod(denied.path, 0);
        final result = await invoke(
          ['init', '--root', denied.path, '--template', 'dart', '--dry-run'],
          2,
          unprivileged: true,
        );
        _check(
          result['status'] == 'error' && result['payload'] == null,
          'Unreadable root must fail before preparing an init outcome',
        );
      } finally {
        _chmod(denied.path, 0x1c0); // 0700: restore before recursive cleanup.
      }
    }
    for (final args in [
      ['--help'],
      ['--version'],
      ['init', '--help'],
    ]) {
      final result = await run(args);
      _check(
        result.exitCode == 0 &&
            (result.stderr as List).isEmpty &&
            utf8.decode(result.stdout as List<int>).startsWith('archway'),
        '$args: informational transport: ${result.stdout}; ${result.stderr}',
      );
      count++;
    }
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln(
    '$count real executable transport/schema checks passed (runtime PATH cleared).',
  );
}

void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}

void _chmod(String path, int mode) {
  final libc = DynamicLibrary.process();
  final chmod = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  final nativePath = path.toNativeUtf8();
  try {
    if (chmod(nativePath, mode) != 0)
      throw OSError('chmod $path', errno().value);
  } finally {
    malloc.free(nativePath);
  }
}
