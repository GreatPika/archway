// Native acceptance building blocks. Full source-gate integration is separate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'native_acceptance_capture.dart';

const fixtureKeys = [
  'dart_sdk',
  'wrong_node',
  'pub_fixture',
  'git_fixture',
  'flutter_sdk',
  'flutter_fixture',
];
const suiteTimeout = Duration(seconds: 600);
typedef AcceptanceCommand = ({String name, List<String> command});

List<AcceptanceCommand> suiteCommands(
  String repository,
  String executable,
  String node,
  Map<String, String> fixtures,
  String output,
) {
  final windows =
      p.windows.isAbsolute(executable) && !p.posix.isAbsolute(executable);
  final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  final target = paths.basename(paths.dirname(executable));
  if (!['linux-x64', 'macos-arm64', 'windows-x64'].contains(target)) {
    throw ArgumentError('Unsupported archive target: $target');
  }
  final sdk = fixtures['dart_sdk']!;
  final arguments = <String, List<String>>{
    'plan_query': [],
    'cli': [],
    'catalogue_export': [],
    'check': [node],
    'dart_check': [sdk, node, '--existing-installation'],
    'physical_path': [sdk, node],
    'alias_wire': [node],
    'alias_hop_recheck': [node],
    'alias_trace_gap': [node],
    'dart_resource': [sdk],
    'runtime': [node],
    'runtime_request': [
      node,
      paths.join(output, 'runtime-request-coverage.json'),
    ],
    'runtime_preflight': [node, fixtures['wrong_node']!, sdk],
    'native_asset': [],
    'native_abi': [],
    'native_fault': [],
    'package_provenance': [
      repository,
      fixtures['pub_fixture']!,
      fixtures['git_fixture']!,
      paths.join(output, 'package-provenance'),
    ],
    'dart_flutter': [fixtures['flutter_sdk']!, fixtures['flutter_fixture']!],
  };
  return [
    for (final entry in arguments.entries)
      (
        name: entry.key,
        command: [
          paths.join(sdk, 'bin', target == 'windows-x64' ? 'dart.exe' : 'dart'),
          '--suppress-analytics',
          'run',
          paths.join(repository, 'test', '${entry.key}_process_smoke.dart'),
          executable,
          ...entry.value,
        ],
      ),
  ];
}

typedef AcceptanceFixtures = ({
  Map<String, String> paths,
  Map<String, String> environment,
  Map<String, Object?> provenance,
});

AcceptanceFixtures readFixtures(File file) {
  final bytes = file.readAsBytesSync();
  final manifest = jsonDecode(utf8.decode(bytes));
  if (manifest is! Map<String, dynamic>)
    throw const FormatException('Expected fixture manifest object');
  final paths = <String, String>{};
  for (final key in fixtureKeys) {
    final value = manifest[key];
    if (value is! String || !p.isAbsolute(value)) {
      throw FormatException('Acceptance fixture $key must be an absolute path');
    }
    final expected = key == 'wrong_node'
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (FileSystemEntity.typeSync(value) != expected) {
      throw FormatException('Acceptance fixture $key is missing: $value');
    }
    paths[key] = key == 'wrong_node'
        ? File(value).resolveSymbolicLinksSync()
        : Directory(value).resolveSymbolicLinksSync();
  }
  final environment = manifest.containsKey('environment')
      ? manifest['environment']
      : <String, String>{};
  if (environment is! Map<String, dynamic> ||
      environment.values.any((v) => v is! String)) {
    throw const FormatException(
      'Acceptance fixture environment must contain string values',
    );
  }
  return (
    paths: paths,
    environment: environment.cast<String, String>(),
    provenance: {
      'sha256': sha256.convert(bytes).toString(),
      'manifest': manifest,
    },
  );
}

Map<String, String> fixtureEnvironment(
  AcceptanceFixtures fixtures,
  String node,
  Map<String, String> parent,
) {
  final result = {...parent, ...fixtures.environment};
  result['PATH'] = [
    p.join(fixtures.paths['dart_sdk']!, 'bin'),
    p.dirname(node),
    result['PATH'] ?? '',
  ].join(Platform.isWindows ? ';' : ':');
  return result;
}

final class SuiteExitFailure implements Exception {
  SuiteExitFailure(this.proof);
  final Map<String, Object?> proof;
  @override
  String toString() =>
      'Native acceptance suite ${proof['suite']} failed with exit ${proof['exit_code']}';
}

Future<Map<String, Object?>> executeSuite(
  String name,
  List<String> command,
  String repository,
  Map<String, String> environment,
  Directory output, {
  Duration timeout = suiteTimeout,
}) async {
  if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name) ||
      command.isEmpty ||
      timeout <= Duration.zero) {
    throw ArgumentError('Expected suite name, command and positive timeout');
  }
  final files = [
    for (final suffix in ['stdout.log', 'stderr.log', 'json'])
      File(p.join(output.path, '$name.$suffix')),
  ];
  // Reserve every evidence name before launching; no prior evidence is replaced.
  for (final file in files) {
    file.createSync(exclusive: true);
  }
  final out = files[0].openSync(mode: FileMode.writeOnly);
  RandomAccessFile? err;
  final elapsed = Stopwatch()..start();
  int? code;
  var timedOut = false;
  Object? failure;
  StackTrace? stack;
  try {
    err = files[1].openSync(mode: FileMode.writeOnly);
    code = await captureAcceptanceProcess(
      command,
      repository,
      environment,
      out,
      err,
      timeout,
    );
  } catch (error, trace) {
    timedOut = error is TimeoutException;
    failure = error;
    stack = trace;
  } finally {
    try {
      out.closeSync();
    } finally {
      err?.closeSync();
    }
  }
  final proof = <String, Object?>{
    'suite': name,
    'command': command,
    'exit_code': code,
    'timed_out': timedOut,
    'elapsed_seconds': (elapsed.elapsedMicroseconds / 1000).round() / 1000,
    'timeout_seconds': timeout.inMicroseconds / Duration.microsecondsPerSecond,
    'stdout': p.basename(files[0].path),
    'stderr': p.basename(files[1].path),
    'stdout_sha256': (await sha256.bind(files[0].openRead()).first).toString(),
    'stderr_sha256': (await sha256.bind(files[1].openRead()).first).toString(),
  };
  // Preserve integer seconds in the established production receipt contract.
  if (timeout.inMicroseconds % Duration.microsecondsPerSecond == 0)
    proof['timeout_seconds'] = timeout.inSeconds;
  files[2].writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(proof)}\n',
    flush: true,
  );
  if (failure != null) Error.throwWithStackTrace(failure, stack!);
  if (code != 0) throw SuiteExitFailure(proof);
  return proof;
}
