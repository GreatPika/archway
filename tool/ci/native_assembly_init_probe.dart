import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../../test/support/windows_process_pipes.dart';
import '../release/installation_artifact.dart';
import '../release/installation_identity.dart';
import '../validation/json_values.dart';
import 'aot_init_assertions.dart';
import 'windows_assembly_assertions.dart';

// Real maintainer assembly/init, not package or clean-platform certification.
final class AssemblyOptions {
  AssemblyOptions._(this.values, this.initOnly);
  final Map<String, String> values;
  final bool initOnly;

  factory AssemblyOptions.parse(List<String> arguments) {
    final values = <String, String>{};
    var initOnly = false;
    const valued = {
      '--artifact-directory',
      '--log-directory',
      '--dart',
      '--dart-sdk',
      '--node',
    };
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument == '--init-only') {
        initOnly = true;
        continue;
      }
      final equal = argument.indexOf('=');
      final option = equal < 0 ? argument : argument.substring(0, equal);
      if (!valued.contains(option))
        throw FormatException('Unknown argument: $argument');
      if (equal >= 0) {
        values[option] = argument.substring(equal + 1);
      } else {
        if (i + 1 == arguments.length || arguments[i + 1].startsWith('--')) {
          throw FormatException('Missing value for $option');
        }
        values[option] = arguments[++i];
      }
    }
    if (values.containsKey('--dart-sdk') != values.containsKey('--node')) {
      throw const FormatException(
        '--dart-sdk and --node must be supplied together',
      );
    }
    if (initOnly && values.containsKey('--dart-sdk')) {
      throw const FormatException(
        '--init-only cannot be combined with mixed compiler checks',
      );
    }
    return AssemblyOptions._(values, initOnly);
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _powerShell() {
  final path = Platform.environment.entries
      .where((entry) => entry.key.toUpperCase() == 'PATH')
      .map((entry) => entry.value)
      .single;
  for (final directory in path.split(';')) {
    final candidate = File(p.join(directory, 'pwsh.exe')).absolute;
    if (candidate.existsSync()) return candidate.path;
  }
  throw StateError('Prerequisite failure: native PowerShell is unavailable.');
}

// The real assembler remains the sole build owner. A tighter timeout is for
// forced-timeout controls only; callers cannot expand the 240-second budget.
Future<void> assembleNativeInstallation(
  Directory repo,
  Directory output,
  Directory base, {
  File? dart,
  Duration timeout = const Duration(seconds: 240),
}) async {
  if (timeout <= Duration.zero || timeout > const Duration(seconds: 240)) {
    throw ArgumentError(
      'Assembly timeout must be positive and at most 240 seconds',
    );
  }
  final command = Platform.isWindows
      ? [
          _powerShell(),
          '-NoProfile',
          '-File',
          p.join(repo.path, 'tool/assemble_windows.ps1'),
          '-Output',
          output.path,
          '-Dart',
          dart!.path,
        ]
      : ['sh', p.join(repo.path, 'tool/assemble.sh'), output.path];
  NativeProcessResult result;
  if (Platform.isWindows) {
    try {
      result = await runNativeProcess(
        command,
        workingDirectory: base.path,
        timeout: timeout,
      );
      stdout.add(result.stdout);
      stderr.add(result.stderr);
    } on WindowsPipeTimeout catch (error) {
      stdout.add(error.stdout);
      stderr.add(error.stderr);
      rethrow;
    }
  } else {
    final out = File(p.join(base.path, 'assembler.stdout'))
      ..createSync(exclusive: true);
    final err = File(p.join(base.path, 'assembler.stderr'))
      ..createSync(exclusive: true);
    try {
      result = await runNativeProcess(
        [
          'sh',
          '-c',
          r'exec "$@" > "$ARCHWAY_ASSEMBLY_STDOUT" 2> "$ARCHWAY_ASSEMBLY_STDERR"',
          'assembly',
          ...command,
        ],
        workingDirectory: base.path,
        timeout: timeout,
        environment: {
          ...Platform.environment,
          'ARCHWAY_ASSEMBLY_STDOUT': out.path,
          'ARCHWAY_ASSEMBLY_STDERR': err.path,
        },
      );
    } finally {
      stdout.add(out.readAsBytesSync());
      stderr.add(err.readAsBytesSync());
    }
  }
  _require(result.exitCode == 0, 'Real assembler failed: ${result.exitCode}');
}

/// Fixed native layout and the original assembler's exact owned asset selection.
({File binary, Set<String> expected}) verifyAssembly(
  Directory bundle,
  Directory sourceAssets,
  String target,
  String bridgeName,
) {
  List<String> names(String relative) =>
      Directory(p.join(bundle.path, relative))
          .listSync(followLinks: false)
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();
  final binaryName = target == 'windows-x64' ? 'archway.exe' : 'archway';
  final binary = File(p.join(bundle.path, 'bin', target, binaryName));
  final bridge = File(p.join(bundle.path, 'native', target, bridgeName));
  _require(
    sameJson(names(''), ['assets', 'bin', 'native']),
    'Unexpected installation root layout.',
  );
  _require(
    sameJson(names('bin'), [target]) &&
        sameJson(names('bin/$target'), [binaryName]),
    'Unexpected executable layout.',
  );
  _require(
    sameJson(names('native'), [target]) &&
        sameJson(names('native/$target'), [bridgeName]),
    'Unexpected bridge layout.',
  );
  String relative(String path, String from) =>
      p.split(p.relative(path, from: from)).join('/');
  final expected = <String>{};
  for (final artifact in [binary, bridge]) {
    _require(
      FileSystemEntity.typeSync(artifact.path, followLinks: false) ==
          FileSystemEntityType.file,
      'Native artifact must be an ordinary file: ${artifact.path}',
    );
    final name = relative(artifact.path, bundle.path);
    expected.add(name);
    print('$name sha256=${sha256.convert(artifact.readAsBytesSync())}');
  }
  final assets = <String, File>{};
  void add(FileSystemEntity entity) {
    if (FileSystemEntity.isFileSync(entity.path)) {
      assets[relative(entity.path, sourceAssets.path)] = File(entity.path);
    }
  }

  for (final entity in sourceAssets.listSync(followLinks: false)) {
    if (['.cjs', '.json', '.md'].any(p.basename(entity.path).endsWith))
      add(entity);
  }
  for (final directory in ['licenses', 'vendor']) {
    final root = Directory(p.join(sourceAssets.path, directory));
    if (root.existsSync()) {
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        add(entity);
      }
    }
  }
  final staged = Directory(p.join(bundle.path, 'assets/typescript'));
  final actual = staged
      .listSync(recursive: true, followLinks: false)
      .where((e) => FileSystemEntity.isFileSync(e.path))
      .map((e) => relative(e.path, staged.path))
      .toSet();
  _require(
    actual.length == assets.length && actual.containsAll(assets.keys),
    'Unexpected staged asset inventory.',
  );
  for (final entry in assets.entries) {
    final file = File(p.join(staged.path, entry.key));
    _require(
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          sameJson(file.readAsBytesSync(), entry.value.readAsBytesSync()),
      'Staged asset differs or is aliased: ${entry.key}',
    );
    expected.add('assets/typescript/${entry.key}');
  }
  print('Verified ${assets.length} exact owned asset files.');
  return (binary: binary, expected: expected);
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    print(
      'Real maintainer assembly/init and process regressions, not package certification.\n'
      'Options: --artifact-directory DIR --log-directory DIR --init-only\n'
      '         --dart EXE (Windows) --dart-sdk SDK --node EXE (paired mixed checks)',
    );
    return;
  }
  late AssemblyOptions options;
  final target = nativeTarget();
  try {
    options = AssemblyOptions.parse(arguments);
    if (Platform.isWindows) {
      if (!options.initOnly || !options.values.containsKey('--dart')) {
        throw const FormatException(
          'Windows assembly requires --init-only and --dart',
        );
      }
    } else if (options.values.containsKey('--dart')) {
      throw const FormatException(
        '--dart is only used by the Windows assembler',
      );
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
    return;
  }
  final values = options.values;
  final repo = Directory.fromUri(Platform.script.resolve('../../'))
      .resolveSymbolicLinksSync();
  final repository = Directory(repo);
  final sourceAssets = Directory(p.join(repo, 'assets/typescript'));
  final dart = values['--dart'] == null
      ? null
      : File(values['--dart']!).resolveSymbolicLinksSync();
  if (dart != null)
    _require(
      File(dart).existsSync(),
      'Windows assembly needs an existing Dart executable.',
    );
  final sdk = values['--dart-sdk'] == null
      ? null
      : Directory(values['--dart-sdk']!).resolveSymbolicLinksSync();
  final node = values['--node'] == null
      ? null
      : File(values['--node']!).resolveSymbolicLinksSync();
  final logs = values['--log-directory'] == null
      ? null
      : Directory(values['--log-directory']!).absolute;
  logs?.createSync(recursive: true);
  // Preserve the destination leaf, including a dangling link; the exporter refuses it.
  final destination = values['--artifact-directory'] == null
      ? null
      : Directory(values['--artifact-directory']!).absolute;
  Map<String, Object>? sourceRecord;
  final runtimes = <String, String>{};
  if (destination != null) {
    _require(
      FileSystemEntity.typeSync(destination.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Artifact destination already exists: ${destination.path}',
    );
    sourceRecord = await sourceIdentity(repository);
    runtimes['build_dart'] = await runtimeVersion(dart ?? 'dart', repository);
    if (sdk != null) {
      runtimes['analysis_dart'] = await runtimeVersion(
        p.join(sdk, 'bin/dart'),
        repository,
      );
      runtimes['analysis_node'] = await runtimeVersion(node!, repository);
    }
  }
  for (final package in {'typescript': '5.9.3', 'yaml': '2.8.1'}.entries) {
    final manifest = File(
      p.join(sourceAssets.path, 'vendor', package.key, 'package.json'),
    );
    _require(
      (jsonDecode(manifest.readAsStringSync()) as Map)['version'] ==
          package.value,
      'Unexpected prepared vendor: ${package.key}',
    );
  }
  for (final name in ['typescript/lib/typescript.js', 'yaml/dist/index.js']) {
    _require(
      File(p.join(sourceAssets.path, 'vendor', name)).existsSync(),
      'Missing prepared vendor: $name',
    );
  }
  final temporary = Directory.systemTemp.createTempSync(
    'archway-native-assembly-',
  );
  final base = Directory(temporary.resolveSymbolicLinksSync());
  try {
    final output = Directory(p.join(base.path, 'assembled café installation'));
    await assembleNativeInstallation(
      repository,
      output,
      base,
      dart: dart == null ? null : File(dart),
    );
    final bundle = output.renameSync(
      p.join(base.path, 'relocated ü installation'),
    );
    final layout = verifyAssembly(
      bundle,
      sourceAssets,
      target.target,
      target.library,
    );
    await assertAotInit(layout.binary, base);
    if (Platform.isWindows)
      await assertWindowsAssemblyGuards(
        repository,
        _powerShell(),
        File(dart!),
        base,
      );
    final suites = <(String, String)>[
      if (!options.initOnly) ...[
        ('native_asset_process_smoke.dart', 'assembly-assets.log'),
        ('cli_process_smoke.dart', 'assembly-cli.log'),
      ],
      if (sdk != null) ...[
        ('dart_check_process_smoke.dart', 'assembly-compilers.log'),
        ('alias_trace_gap_process_smoke.dart', 'assembly-alias-trace.log'),
      ],
    ];
    for (final (suite, logName) in suites) {
      final command = [
        Platform.resolvedExecutable,
        p.join(repo, 'test', suite),
        layout.binary.path,
        if (suite == 'dart_check_process_smoke.dart') ...[
          sdk!,
          node!,
          '--existing-installation',
        ],
        if (suite == 'alias_trace_gap_process_smoke.dart') node!,
      ];
      final log = File(p.join((logs ?? base).path, logName));
      print('Running $suite against ${layout.binary.path}');
      // Process profiles are POSIX-only. exec preserves the child PID; shell
      // redirection retains merged stream order and partial evidence on timeout.
      log.writeAsBytesSync([]);
      try {
        final result = await runNativeProcess(
          [
            'sh',
            '-c',
            r'exec "$@" > "$ARCHWAY_ASSEMBLY_LOG" 2>&1',
            'assembly-suite',
            ...command,
          ],
          workingDirectory: base.path,
          environment: {
            ...Platform.environment,
            'ARCHWAY_ASSEMBLY_LOG': log.path,
          },
          timeout: const Duration(seconds: 120),
        );
        _require(result.exitCode == 0, '$suite failed: ${result.exitCode}');
      } finally {
        stdout.add(log.readAsBytesSync());
      }
    }
    if (destination != null) {
      _require(
        sameJson(await sourceIdentity(repository), sourceRecord),
        'Tracked source identity changed during assembly checks',
      );
      final release = Platform.isWindows
          ? Platform.operatingSystemVersion
          : utf8
                .decode(
                  (await runNativeProcess(
                    ['uname', '-r'],
                    timeout: const Duration(seconds: 30),
                    workingDirectory: repo,
                  )).stdout,
                )
                .trim();
      _require(release.isNotEmpty, 'Missing observed host release');
      final provenance = <String, Object?>{
        'source': sourceRecord,
        'target': target.target,
        'host': {
          'system': Platform.isWindows
              ? 'Windows'
              : Platform.isMacOS
              ? 'Darwin'
              : 'Linux',
          'machine': Platform.isWindows
              ? 'AMD64'
              : Platform.isMacOS
              ? 'arm64'
              : 'x86_64',
          'release': release,
        },
        'checks': {
          'profile': options.initOnly ? 'init-only' : 'process',
          'suites': [for (final (suite, _) in suites) suite],
          'relocated_init': true,
          'transported_init': true,
        },
        'runtimes': runtimes,
      };
      await exportInstallation(
        bundle,
        destination,
        layout.expected,
        provenance,
        (extracted, freshBase) async {
          await assertAotInit(
            File(
              p.join(
                extracted.path,
                p.relative(layout.binary.path, from: bundle.path),
              ),
            ),
            freshBase,
          );
          _require(
            sameJson(await sourceIdentity(repository), sourceRecord),
            'Tracked source changed during transport checks',
          );
        },
      );
      print('Verified installation artifact: ${destination.path}');
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
  print(
    options.initOnly
        ? 'Genuine assembled ${target.target} AOT init passed after relocation with Dart/Node absent from PATH; process regressions were not requested.'
        : 'Genuine assembled ${target.target} AOT init and process regressions passed after relocation, with baseline init/asset/CLI checks excluding Dart/Node from PATH.',
  );
  if (sdk != null)
    print(
      'Mixed compiler checks passed using explicitly supplied pinned external runtimes.',
    );
}
