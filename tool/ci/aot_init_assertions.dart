// Shared real-process init oracle: contracts/json/decision.md and mixed template.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../validation/json_values.dart';

Future<NativeProcessResult> assertAotInit(
  File binary,
  Directory base, {
  List<String> Function(List<String>)? command,
  Map<String, String>? environment,
  String label = 'AOT',
  Duration timeout = const Duration(seconds: 30),
  Future<NativeProcessResult> Function(
        List<String>, {
        required Duration timeout,
        String? workingDirectory,
        Map<String, String>? environment,
      })
      run =
      runNativeProcess,
}) async {
  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  final cwd = Directory(p.join(base.path, 'unrelated cwd ü'))..createSync();
  final root = Directory(p.join(base.path, 'empty project café'))..createSync();
  require(root.listSync().isEmpty, 'Init project must start empty.');
  final runtimePath = p.join(base.path, 'no-runtime-here');
  require(
    p.isAbsolute(runtimePath) && !Directory(runtimePath).existsSync(),
    'No-runtime PATH must be absolute and absent.',
  );
  final arguments = [
    binary.path,
    '--root',
    root.path,
    'init',
    '--template',
    'mixed',
  ];
  final result = await run(
    command == null ? arguments : command(arguments),
    workingDirectory: cwd.path,
    environment:
        environment ??
        {
          for (final entry in Platform.environment.entries)
            if (entry.key.toUpperCase() != 'PATH') entry.key: entry.value,
          'PATH': runtimePath,
        },
    timeout: timeout,
  );
  print('$label init exit: ${result.exitCode}');
  print(
    '$label stdout: ${jsonEncode(utf8.decode(result.stdout, allowMalformed: true))}',
  );
  print(
    '$label stderr: ${jsonEncode(utf8.decode(result.stderr, allowMalformed: true))}',
  );
  require(result.exitCode == 0, 'Real $label init must succeed.');
  require(result.stderr.isEmpty, 'Init stderr must be empty.');
  final output = result.stdout;
  require(
    output.isNotEmpty &&
        output.last == 10 &&
        output.where((b) => b == 10).length == 1,
    'Expected one JSON line followed by LF.',
  );
  require(
    !(output.length >= 3 &&
        output[0] == 0xef &&
        output[1] == 0xbb &&
        output[2] == 0xbf),
    'Init stdout must not start with a UTF-8 BOM.',
  );
  final value = jsonDecode(utf8.decode(output)) as Map<String, dynamic>;
  require(
    value['schema_version'] == 1 &&
        value['command'] == 'init' &&
        value['status'] == 'ok' &&
        value['exit_code'] == 0 &&
        sameJson(value['diagnostics'], []),
    'Unexpected init envelope.',
  );
  require(
    sameJson(value['payload'], {
      'template': 'mixed',
      'dry_run': false,
      'outcome': 'created',
      'planned_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
      'planned_files': [],
      'created_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
      'residual_paths': [],
      'conflicting_paths': [],
    }),
    'Unexpected init payload.',
  );
  final names = root.listSync().map((e) => p.basename(e.path)).toList()..sort();
  require(
    sameJson(names, ['ARCHITECTURE.md', 'architecture.yaml']),
    'Init must create exactly the two bootstrap files.',
  );
  require(
    sameJson(
      File(p.join(root.path, 'architecture.yaml')).readAsBytesSync(),
      utf8.encode(
        '# Archway: mixed template\nversion: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      ),
    ),
    'Unexpected init policy bytes.',
  );
  // Python's text read normalizes newlines; policy validation above remains raw.
  final guide = File(p.join(root.path, 'ARCHITECTURE.md'))
      .readAsStringSync()
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  require(
    guide.startsWith('# Architecture agent workflow\n') &&
        guide.contains('Init never overwrites or merges files.') &&
        guide.contains('Init does not edit AGENTS.md, CI, or editor settings.'),
    'Unexpected init guide.',
  );
  require(cwd.listSync().isEmpty, 'Init modified the unrelated cwd.');
  return result;
}
