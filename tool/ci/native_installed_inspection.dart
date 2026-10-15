// Read-only callback for native installer callers; suites keep their own owner.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import 'installed_command_recorder.dart';
import 'native_acceptance.dart';
import 'native_installed_commands.dart';
import 'native_source_acceptance.dart' show SourceExecute;

Future<Map<String, Object?>> inspectInstalledCommands(
  File binary,
  Directory installation, {
  required String target,
  required String version,
  required Directory repository,
  required Directory base,
  required File node,
  required File fixtureFile,
  required Directory output,
  SourceExecute execute = executeSuite,
}) async {
  // Installed behavior only; overall release acceptance separately certifies prepared runtime identity.
  final fixtures = readFixtures(fixtureFile);
  final wrongNode = File(fixtures.paths['wrong_node']!);
  final recorder = InstalledCommandRecorder(output: output);
  final result = await runInstalledCommands(
    binary,
    installation,
    base,
    node,
    recorder,
    readOnly: true,
    version: version,
  );
  final cases = <Map<String, Object?>>[];
  for (final name in ['missing-node', 'wrong-node']) {
    final environment = installedRuntimeEnvironment(
      Platform.environment,
      name == 'wrong-node'
          ? wrongNode.parent.path
          : p.join(base.path, 'no-runtime'),
    );
    final process = await recorder.capture(
      [binary.path, '--root', p.join(base.path, 'prepared project'), 'check'],
      workingDirectory: p.join(base.path, 'foreign'),
      environment: environment,
      expectedExit: 2,
    );
    final value = jsonDecode(utf8.decode(process.stdout));
    final errors = (value['payload']['tool_errors'] as List)
        .map((e) => e['code'])
        .toList();
    if (!sameJson(errors, ['NODE_UNAVAILABLE']) || process.stderr.isNotEmpty) {
      throw StateError('Installed external-runtime failure differs');
    }
    cases.add({'case': name, 'exit': process.exitCode, 'errors': errors});
  }
  final suites = Directory(p.join(output.path, 'suites'))..createSync();
  final environment = fixtureEnvironment(
    fixtures,
    node.path,
    Platform.environment,
  );
  return {
    ...result,
    'binary': binary.path,
    'installation_root': installation.path,
    'manifest_sha256': sha256
        .convert(
          File(p.join(installation.path, 'manifest.json')).readAsBytesSync(),
        )
        .toString(),
    'processes': recorder.commands,
    'runtime_controls': cases,
    'suites': [
      for (final suite in suiteCommands(
        repository.path,
        binary.path,
        node.path,
        fixtures.paths,
        suites.path,
        target: target,
      ))
        if (['plan_query', 'dart_check'].contains(suite.name))
          await execute(
            suite.name,
            suite.command,
            repository.path,
            environment,
            suites,
            timeout: suiteTimeout,
          ),
    ],
  };
}
