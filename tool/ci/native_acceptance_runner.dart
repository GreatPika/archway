// Orchestrate final archive suites without changing their execution/evidence owner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/installation_identity.dart';
import 'native_acceptance.dart';
import 'native_source_acceptance.dart';

typedef SourceRunner = Future<Map<String, Object?>> Function(
  Directory repository,
  String executable,
  Map<String, String> fixtures,
  Map<String, String> environment,
  Directory output, {
  SourceExecute execute,
});

Future<Map<String, Object?>> runAcceptance(
  Directory repository,
  String executable,
  String node,
  File fixtureFile,
  Directory output,
  FutureOr<void> Function() verifyInstallation, {
  SourceExecute execute = executeSuite,
  SourceRunner source = runSourceTests,
}) async {
  final identity = await sourceIdentity(repository);
  final fixtures = readFixtures(fixtureFile);
  if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('Acceptance output already exists', output.path);
  }
  output.createSync(recursive: true);
  repository = Directory(repository.resolveSymbolicLinksSync());
  output = Directory(output.resolveSymbolicLinksSync());
  node = File(node).resolveSymbolicLinksSync();
  final environment = fixtureEnvironment(fixtures, node, Platform.environment);
  final results = <Map<String, Object?>>[];
  final failures = <Map<String, String>>[];
  void recordFailure(String name, Object error) {
    failures.add({'suite': name, 'error': '$error'});
    File(p.join(output.path, 'failures.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(failures)}\n',
      flush: true,
    );
  }

  for (final suite in suiteCommands(
    repository.path,
    executable,
    node,
    fixtures.paths,
    output.path,
  )) {
    await verifyInstallation();
    try {
      results.add(
        await execute(
          suite.name,
          suite.command,
          repository.path,
          environment,
          output,
          timeout: suiteTimeout,
        ),
      );
    } on SuiteExitFailure catch (error) {
      results.add(error.proof);
      recordFailure(suite.name, error);
    } finally {
      await verifyInstallation();
    }
  }
  await verifyInstallation();
  late Map<String, Object?> sourceSuite;
  try {
    sourceSuite = await source(
      repository,
      executable,
      fixtures.paths,
      environment,
      output,
      execute: execute,
    );
  } catch (error) {
    // Source preparation remains fail-fast. No process follows this diagnostic.
    recordFailure('source', error);
  } finally {
    await verifyInstallation();
  }
  if (jsonEncode(await sourceIdentity(repository)) != jsonEncode(identity)) {
    throw StateError('Acceptance test sources changed during execution');
  }
  if (failures.isNotEmpty) {
    throw StateError(
      'Native acceptance failed: ${failures.map((f) => "${f['suite']}: ${f['error']}").join('; ')}',
    );
  }
  return {
    'scope': 'Complete applicable final native archive process suites',
    'source': identity,
    'source_root': repository.path,
    'node_path': node,
    'output_root': output.path,
    'fixtures': fixtures.provenance,
    'suites': results,
    'source_suite': sourceSuite,
  };
}
