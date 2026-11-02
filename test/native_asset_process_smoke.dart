// Real relocated native AOT asset loading; read-only commands need no bridge.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, dynamic> decode(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError(
      'Usage: dart test/native_asset_process_smoke.dart <executable>',
    );
  }
  final repository = File.fromUri(Platform.script).parent.parent;
  ContractSchema schema(String name) => ContractSchema(
    jsonDecode(
      File(p.join(repository.path, 'contracts', 'json', name))
          .readAsStringSync(),
    ),
  );
  final public = schema('public-result.schema.json');
  final export = schema('export-diagnostics.schema.json');
  final target = nativeTarget();
  final executableName = Platform.isWindows ? 'archway.exe' : 'archway';
  final executable = File(File(arguments.single).resolveSymbolicLinksSync());
  check(
    p.joinAll(p.split(executable.path).reversed.take(2).toList().reversed) ==
        p.join('bin', executableName),
    'Expected native executable layout: ${executable.path}',
  );
  final temporary = Directory.systemTemp.createTempSync(
    'archway-native-assets-',
  );
  var count = 0;
  try {
    final base = Directory(temporary.resolveSymbolicLinksSync());
    final bundle = Directory(p.join(base.path, 'relocated café bundle'));
    var binary = stageInstallation(executable, bundle);
    final asset = File(p.join(bundle.path, 'lib', target.library));
    final cwd = Directory(p.join(base.path, 'unrelated cwd'));
    Directory(p.join(cwd.path, 'lib')).createSync(recursive: true);
    final root = Directory(p.join(base.path, 'project'))..createSync();
    File project(String name) => File(p.join(root.path, name));
    final decoys = [
      File(p.join(cwd.path, 'lib', target.library)),
      File(p.join(root.path, 'lib', target.library)),
    ];
    for (final decoy in decoys) {
      decoy.parent.createSync(recursive: true);
      decoy.writeAsStringSync(
        'Never load a library from cwd or the inspected root',
      );
    }
    final realAssetBytes = asset.readAsBytesSync();
    void absent(String name) =>
        check(!project(name).existsSync(), 'Unexpected output: $name');
    Future<NativeProcessResult> invoke(List<String> args, int expected) async {
      final result = await runNativeProcess(
        [binary.path, '--root', root.path, ...args],
        timeout: const Duration(seconds: 10),
        workingDirectory: cwd.path,
        environment: {
          // Windows environment keys are case-insensitive.
          for (final entry in Platform.environment.entries)
            if (entry.key.toUpperCase() != 'PATH') entry.key: entry.value,
          'PATH': '/no-runtime-here',
        },
      );
      check(result.exitCode == expected, '$args: $result');
      if (args.first == 'export') {
        if (expected != 0) {
          check(result.stdout.isEmpty, '$args: unexpected stdout');
        }
        if (result.stderr.isNotEmpty) {
          final errors = export.errors(decode(result.stderr));
          check(errors.isEmpty, 'Export schema: $errors');
        }
      } else {
        check(result.stderr.isEmpty, '$args: unexpected stderr');
        final errors = public.errors(decode(result.stdout));
        check(errors.isEmpty, 'Public schema: $errors');
      }
      count++;
      return result;
    }

    await invoke(['init', '--template', 'dart'], 0);
    await invoke(['export', '--format', 'mermaid', '--out', 'valid.mmd'], 0);
    check(
      project('valid.mmd').readAsStringSync().endsWith('flowchart LR\n'),
      'Unexpected Mermaid output',
    );
    // SDK resolution owns the trusted installation, as defined by delivery.
    // Installation-local aliases are supported by the SDK, not tamper protection.
    // Project/output alias restrictions remain independently tested.
    final original = asset.renameSync(
      p.join(asset.parent.path, 'original${p.extension(asset.path)}'),
    );
    Link(asset.path).createSync(original.path);
    await invoke(['export', '--format', 'mermaid', '--out', 'aliased.mmd'], 0);
    check(
      project('aliased.mmd').readAsStringSync() ==
          project('valid.mmd').readAsStringSync(),
      'SDK direct asset alias changed output',
    );
    Link(asset.path).deleteSync();
    original.renameSync(asset.path);
    final originalParent = asset.parent.renameSync(
      p.join(bundle.path, 'real-native'),
    );
    Link(asset.parent.path).createSync(originalParent.path);
    await invoke([
      'export',
      '--format',
      'mermaid',
      '--out',
      'aliased-parent.mmd',
    ], 0);
    check(
      project('aliased-parent.mmd').readAsStringSync() ==
          project('valid.mmd').readAsStringSync(),
      'SDK parent asset alias changed output',
    );
    Link(asset.parent.path).deleteSync();
    originalParent.renameSync(asset.parent.path);
    // Valid libraries in cwd/project must not rescue a missing installed asset.
    for (final decoy in decoys) {
      decoy.writeAsBytesSync(realAssetBytes);
    }
    asset.deleteSync();
    await invoke(['validate'], 0);
    await invoke(['node'], 0);
    await invoke(['export', '--format', 'mermaid'], 0);
    final missing = await invoke([
      'export',
      '--format',
      'mermaid',
      '--out',
      'missing.mmd',
    ], 2);
    absent('missing.mmd');
    check(
      decode(missing.stderr)['diagnostics'].last['code'] ==
          'EXPORT_WRITE_FAILED',
      'Missing asset export diagnostic',
    );
    project('architecture.yaml').deleteSync();
    project('ARCHITECTURE.md').deleteSync();
    final preview = await invoke([
      'init',
      '--template',
      'dart',
      '--dry-run',
    ], 0);
    check(
      jsonEncode(decode(preview.stdout)['payload']['planned_paths']) ==
          jsonEncode(['architecture.yaml', 'ARCHITECTURE.md']),
      'Dry-run planned paths',
    );
    final alias = project('architecture.md')
      ..writeAsStringSync('keep user guide');
    for (final suffix in [
      <String>['--dry-run'],
      <String>[],
    ]) {
      final conflict = await invoke([
        'init',
        '--template',
        'dart',
        ...suffix,
      ], 2);
      final payload = decode(conflict.stdout)['payload'];
      check(payload['outcome'] == 'conflict', 'Expected init conflict');
      check(
        jsonEncode(payload['conflicting_paths']) ==
            jsonEncode(['ARCHITECTURE.md']),
        'Init conflicting paths',
      );
      check((payload['created_paths'] as List).isEmpty, 'Init created paths');
      check(
        alias.readAsStringSync() == 'keep user guide',
        'User guide changed',
      );
      absent('architecture.yaml');
    }
    alias.deleteSync();
    final missingInit = await invoke(['init', '--template', 'dart'], 2);
    check(
      decode(missingInit.stdout)['diagnostics'][0]['code'] ==
          'INIT_UNAVAILABLE',
      'Missing asset init diagnostic',
    );
    absent('architecture.yaml');

    // Keep the real ABI layout/symbols; mutate only the rejected version.
    final wrongSource = File(p.join(base.path, 'wrong_version.c'));
    final source = File(p.join(repository.path, 'native', target.source))
        .readAsStringSync();
    const version = 'archway_io_version(void) { return 2; }';
    check(
      version.allMatches(source).length == 1,
      'Expected exactly one ABI version definition',
    );
    // A correct version with an incomplete allocator ABI must fail before writes.
    final missingFree = source.replaceFirst(
      'archway_io_free(void *pointer)',
      'archway_io_free_missing(void *pointer)',
    );
    check(missingFree != source, 'Expected native allocator definition');
    wrongSource.writeAsStringSync(missingFree);
    await buildNativeLibrary(wrongSource, asset);
    await invoke(['init', '--template', 'dart'], 2);
    absent('architecture.yaml');

    wrongSource.writeAsStringSync(
      source.replaceFirst(version, 'archway_io_version(void) { return 1; }'),
    );
    await buildNativeLibrary(wrongSource, asset);
    final wrongInit = await invoke(['init', '--template', 'dart'], 2);
    check(
      (decode(wrongInit.stdout)['diagnostics'][0]['message'] as String)
          .contains('Unsupported native I/O ABI'),
      'Wrong ABI init diagnostic',
    );
    absent('architecture.yaml');
    project('architecture.yaml').writeAsStringSync(
      'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
    );
    await invoke(['export', '--format', 'mermaid', '--out', 'wrong.mmd'], 2);
    absent('wrong.mmd');
    final detached = Directory(p.join(base.path, 'detached'))..createSync();
    binary = binary.copySync(p.join(detached.path, executableName));
    await invoke(['validate'], 0);
    await invoke(['export', '--format', 'mermaid', '--out', 'detached.mmd'], 2);
    absent('detached.mmd');
    check(count == 17, 'Incomplete native asset scenario inventory: $count');
  } finally {
    temporary.deleteSync(recursive: true);
  }
  stdout.writeln(
    '$count relocated/missing/wrong-ABI ${target.target} native asset cases passed',
  );
}
