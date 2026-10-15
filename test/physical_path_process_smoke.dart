// Bounded native malformed-name probes; public CLI JSON is the acceptance seam.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import 'support/native_file_fixtures.dart';
import 'support/native_process_support.dart';
import 'support/raw_symlink_fixture.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln(
      'Usage: dart run test/physical_path_process_smoke.dart <executable> <sdk> <node>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(arguments[0]).resolveSymbolicLinksSync();
  final sdk = Directory(arguments[1]).resolveSymbolicLinksSync();
  final node = File(arguments[2]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  var count = 0;
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-physical-process-')
        .resolveSymbolicLinksSync(),
  );
  Future<Map<String, dynamic>> invoke(
    String selected,
    int expected, {
    String command = 'validate',
    String? binary,
  }) async {
    final result = await runNativeProcess(
      [binary ?? executable, '--root', selected, command],
      timeout: const Duration(seconds: 10),
      environment: {
        ...Platform.environment,
        'PATH':
            '${p.join(sdk, 'bin')}${Platform.isWindows ? ';' : ':'}${p.dirname(node)}',
      },
    );
    _check(result.exitCode == expected, 'Expected exit $expected: $result');
    _check(result.stderr.isEmpty, 'Unexpected stderr: $result');
    _check(
      result.stdout.where((b) => b == 10).length == 1,
      'Expected one JSON line: $result',
    );
    final value =
        jsonDecode(utf8.decode(result.stdout)) as Map<String, dynamic>;
    _check(
      schema.errors(value).isEmpty,
      'Public schema: ${schema.errors(value)}',
    );
    _check(value['exit_code'] == expected, 'Public exit code: $value');
    count++;
    return value;
  }

  // Node preserves Buffer paths on POSIX; Win32 calls preserve UTF-16 on Windows.
  Future<void> link(
    String path,
    String target, {
    bool directory = false,
    List<int>? raw,
  }) async {
    if (Platform.isWindows) {
      createWindowsRawLink(path, target, directory: directory);
      final observed = readWindowsRawLink(path);
      final normalized = observed.startsWith('\\??\\')
          ? observed.substring(4)
          : observed;
      _check(normalized == target, 'Raw UTF-16 alias target changed');
    } else {
      final bytes = raw ?? utf8.encode(target);
      final result = await runNativeProcess([
        node,
        '-e',
        "const fs=require('node:fs'),target=Buffer.from(${jsonEncode(bytes)}),path=${jsonEncode(path)};fs.symlinkSync(target,path);if(!fs.readlinkSync(path,{encoding:'buffer'}).equals(target))throw Error('Raw UTF-8 alias target changed');",
      ], timeout: const Duration(seconds: 10));
      _check(result.exitCode == 0, 'Raw alias fixture: $result');
    }
  }

  Future<void> malformedLink(
    String path,
    MalformedNativeFile target, {
    bool directory = false,
  }) => link(
    path,
    target.windowsPath,
    directory: directory,
    raw: target.posixPath,
  );
  const emptyConfig =
      'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n';
  try {
    final root = Directory(p.join(base.path, 'project'))..createSync();
    File(p.join(root.path, 'architecture.yaml')).writeAsStringSync(emptyConfig);
    _check((await invoke(root.path, 0))['status'] == 'ok', 'Baseline status');
    final longAlias = p.join(base.path, 'long-root');
    final longTarget =
        '${List.filled(200, '.${Platform.pathSeparator}').join()}project';
    _check(utf8.encode(longTarget).length == 407, 'Long target byte count');
    await link(longAlias, longTarget, directory: true);
    _check(
      FileSystemEntity.isLinkSync(longAlias) &&
          Directory(longAlias).existsSync(),
      'Long alias not traversable',
    );
    _check(
      Directory(longAlias).resolveSymbolicLinksSync() == root.path,
      'Long alias identity',
    );
    _check(
      File(p.join(longAlias, 'architecture.yaml')).readAsStringSync() ==
          emptyConfig,
      'Long alias contents',
    );
    stdout.writeln(
      'LONG_ALIAS_FIXTURE_READY raw_target_bytes=407 dot_components=200',
    );
    _check(
      (await invoke(longAlias, 0))['resolved_root'] == root.path,
      'Long alias CLI identity',
    );
    final cycle = p.join(base.path, 'cycle');
    await link(cycle, 'cycle', directory: true);
    _check((await invoke(cycle, 2))['status'] == 'error', 'Cycle status');
    for (var index = 0; index < 41; index++) {
      await link(
        p.join(base.path, 'hop$index'),
        index < 40 ? 'hop${index + 1}' : 'project',
        directory: true,
      );
    }
    _check(
      (await invoke(p.join(base.path, 'hop0'), 2))['status'] == 'error',
      'Hop-limit status',
    );
    final rawDirectory = MalformedNativeFile(base.path, 'raw');
    if (Platform.isMacOS) {
      _apfsRejects(base, rawDirectory.createDirectory);
    } else {
      rawDirectory.createDirectory();
    }
    final alias = p.join(base.path, 'invalid-root');
    await malformedLink(alias, rawDirectory, directory: true);
    _check(
      (await invoke(alias, 2))['status'] == 'error',
      'Malformed root status',
    );
    if (!Platform.isMacOS) rawDirectory.deleteDirectory();

    final names = Directory(p.join(base.path, 'raw-names'))..createSync();
    File(
      p.join(names.path, 'architecture.yaml'),
    ).writeAsStringSync(emptyConfig.replaceFirst('scope: []', 'scope: [./]'));
    final rawName = MalformedNativeFile(names.path, 'bad', suffix: '.ts');
    final replacementSource = File(p.join(names.path, 'bad�.ts'));
    if (Platform.isMacOS) {
      _apfsRejects(names, rawName.create);
      replacementSource.writeAsStringSync('export {};');
    } else {
      rawName.create(utf8.encode('export {};'));
      for (final collision in [false, true]) {
        if (collision) replacementSource.writeAsStringSync('export {};');
        final value = await invoke(names.path, 2, command: 'check');
        _check(
          _enumerationFailed(value),
          'Malformed inventory accepted: $value',
        );
      }
      rawName.delete();
    }
    final value = await invoke(names.path, 2, command: 'check');
    _check(
      value['payload']['observed']['files'] == 1,
      'Valid replacement file lost',
    );
    _check(!_enumerationFailed(value), 'Valid replacement file rejected');

    final replacement = Directory(p.join(base.path, 'valid�'))..createSync();
    File(p.join(root.path, 'architecture.yaml'))
        .copySync(p.join(replacement.path, 'architecture.yaml'));
    Link(alias).deleteSync();
    await link(alias, replacement.path, directory: true);
    _check(
      (await invoke(alias, 0))['resolved_root'] == replacement.path,
      'Valid replacement root rejected',
    );
    final isolated = Directory(
      p.join(base.path, 'no-bridge', 'bin', p.basename(p.dirname(executable))),
    )..createSync(recursive: true);
    final isolatedBinary = File(executable)
        .copySync(p.join(isolated.path, p.basename(executable)));
    if (!Platform.isWindows) {
      final chmod = await runNativeProcess([
        'chmod',
        '+x',
        isolatedBinary.path,
      ], timeout: const Duration(seconds: 10));
      _check(chmod.exitCode == 0, 'Isolated executable mode: $chmod');
    }
    _check(
      (await invoke(root.path, 0, binary: isolatedBinary.path))['status'] ==
          'ok',
      'Ordinary root requires bridge',
    );
    _check(
      (await invoke(alias, 2, binary: isolatedBinary.path))['status'] ==
          'error',
      'Alias accepted without bridge',
    );

    for (final language in ['dart', 'typescript']) {
      final project = Directory(p.join(base.path, language));
      Directory(p.join(project.path, 'src')).createSync(recursive: true);
      final dart = language == 'dart';
      File(p.join(project.path, 'src/main.${dart ? 'dart' : 'ts'}'))
          .writeAsStringSync(dart ? 'class Main {}' : 'export {};');
      final config = p.join(
        project.path,
        dart ? 'analysis_options.yaml' : 'compiler.json',
      );
      final configBytes = utf8.encode(
        dart
            ? '{}'
            : '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
      );
      final rawTarget = MalformedNativeFile(base.path, 'config-$language');
      if (Platform.isMacOS) {
        _apfsRejects(base, rawTarget.create);
      } else {
        rawTarget.create(configBytes);
      }
      await malformedLink(config, rawTarget);
      late final String projectRow;
      if (dart) {
        Directory(p.join(project.path, '.dart_tool')).createSync();
        File(p.join(project.path, '.dart_tool/package_config.json'))
            .writeAsStringSync(
              jsonEncode({
                'configVersion': 2,
                'packages': [
                  {
                    'name': 'fixture',
                    'rootUri': '../',
                    'packageUri': 'src/',
                    'languageVersion': '3.13',
                  },
                ],
              }),
            );
        File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync(
          'name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n',
        );
        projectRow = '{id: app, adapter: dart, package_roots: [./]}';
      } else {
        File(p.join(project.path, 'tsconfig.json')).writeAsStringSync(
          '{"extends":"./compiler.json","include":["src/**/*.ts"]}',
        );
        projectRow = '{id: app, adapter: typescript, tsconfig: tsconfig.json}';
      }
      File(p.join(project.path, 'architecture.yaml')).writeAsStringSync(
        'version: 1\nprojects: [$projectRow]\nscope: [src/]\nexclude: []\nnodes: [{id: app, responsibility: App, owns: [src/], allows: [], public: []}]\n',
      );
      final value = await invoke(project.path, 2, command: 'check');
      _check(
        value['status'] == 'incomplete' &&
            value['payload']['analysis_complete'] == false,
        'Malformed compiler input accepted: $value',
      );
      Link(config).deleteSync();
      if (!Platform.isMacOS) rawTarget.delete();
      File(p.join(project.path, 'config�')).writeAsBytesSync(configBytes);
      await link(config, 'config�');
      _check(
        (await invoke(
              project.path,
              0,
              command: 'check',
            ))['payload']['analysis_complete'] ==
            true,
        'Valid compiler input rejected',
      );
    }
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln(
    '$count bounded real-process physical path checks passed; malformed encoding=${Platform.isWindows ? 'UTF-16' : 'UTF-8'}',
  );
  if (Platform.isMacOS)
    stdout.writeln(
      'APFS rejected malformed entry creation with EILSEQ; malformed symlink targets and valid U+FFFD paths exercised',
    );
}

bool _enumerationFailed(Map<String, dynamic> value) =>
    (value['payload']['unknowns'] as List).any(
      (d) => d['code'] == 'CORPUS_ENUMERATION_FAILED',
    );
void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _apfsRejects(Directory parent, void Function() create) {
  final before = parent
      .listSync(followLinks: false)
      .map((entry) => entry.path)
      .toSet();
  var rejected = false;
  try {
    create();
  } on FileSystemException catch (error) {
    _check(error.osError?.errorCode == 92, 'Expected macOS EILSEQ: $error');
    rejected = true;
  }
  _check(rejected, 'APFS accepted a malformed UTF-8 entry name');
  final after = parent
      .listSync(followLinks: false)
      .map((entry) => entry.path)
      .toSet();
  _check(
    before.length == after.length && before.containsAll(after),
    'Failed creation changed directory entries',
  );
}
