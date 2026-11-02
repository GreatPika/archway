import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Every contract byte must be inventoried before finite checks may execute.
List<String> verifyManifest(Directory root) {
  final manifest = File(path.join(root.path, 'manifest.json'));
  final inventory =
      (jsonDecode(manifest.readAsStringSync()) as Map)['files'] as Map;
  final actual = <String, String>{};
  for (final entry in root.listSync(recursive: true, followLinks: false)) {
    if (!FileSystemEntity.isFileSync(entry.path) || entry.path == manifest.path)
      continue;
    final relative = path.split(path.relative(entry.path, from: root.path));
    // Retain this transitional exclusion until the final Python cutover.
    if (relative.contains('__pycache__') || entry.path.endsWith('.pyc'))
      continue;
    actual[relative.join('/')] = sha256
        .convert(File(entry.path).readAsBytesSync())
        .toString();
  }
  final names = actual.keys.toSet(),
      expected = inventory.keys.cast<String>().toSet();
  return [
    for (final name in names.difference(expected).toList()..sort())
      'unlisted file: $name',
    for (final name in expected.difference(names).toList()..sort())
      'missing file: $name',
    for (final name in names.intersection(expected).toList()..sort())
      if (actual[name] != inventory[name]) 'hash mismatch: $name',
  ];
}

// Explicit suite ownership prevents a renamed or missing group being omitted.
const contractTests = [
  'test/contracts/json_schema_test.dart',
  'test/contracts/json_values_test.dart',
  'test/contracts/public_contract_test.dart',
  'test/contracts/public_boundary_test.dart',
  'test/contracts/assignment_test.dart',
  'test/contracts/lexical_reference_test.dart',
  'test/contracts/cross_contract_test.dart',
  'test/contracts/entrypoint_regressions_test.dart',
  'test/contracts/contract_runner_test.dart',
];

/// Run finite conformance checks, not Archway/compiler/platform certification.
Future<int> runContractChecks(
  Directory root, {
  Future<int> Function()? executeTests,
}) async {
  try {
    final errors = verifyManifest(root);
    if (errors.isNotEmpty) {
      stderr.writeln('Contract manifest failed: ${errors.join('; ')}');
      return 1;
    }
    final status = await (executeTests?.call() ?? _runTests(root));
    return status == 0 ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('Contract checks failed: $error');
    return 1;
  }
}

Future<int> _runTests(Directory root) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['test', ...contractTests],
    workingDirectory: root.absolute.parent.path,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

Future<void> main() async {
  exitCode = await runContractChecks(File.fromUri(Platform.script).parent);
}
