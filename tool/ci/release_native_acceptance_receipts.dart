// Validate native archive evidence independently of the acceptance runner.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import 'native_fixture_pins.dart';
import 'release_execution_receipts.dart';

/// The source gate is validated separately against its verified native manifest.
void validateNative(
  Object? proof,
  File report,
  Directory artifact,
  Map<String, Object?> source,
) {
  final record = _object(proof);
  final target = record['target'];
  if (!fixtureFlutterPins.containsKey(target)) _fail('Unsupported target');
  final windows = target == 'windows-x64';
  final paths = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  String absolute(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.contains('\u0000') ||
        !paths.isAbsolute(value) ||
        (windows && paths.rootPrefix(value).length <= 1))
      _fail('Expected absolute recorded path');
    return value;
  }

  final relocation = _object(record['relocation']);
  final extracted = absolute(relocation['extracted']);
  final executed = absolute(relocation['executed']);
  if (sameEvidencePath(extracted, executed, paths) ||
      relocation['original_removed'] != true) {
    _fail('Native installation was not actually relocated');
  }
  final acceptance = _object(record['acceptance']);
  const fields = {
    'scope',
    'source',
    'source_root',
    'node_path',
    'output_root',
    'fixtures',
    'suites',
    'source_suite',
  };
  if (acceptance.length != fields.length ||
      !fields.every(acceptance.containsKey) ||
      acceptance['scope'] !=
          'Complete applicable final native archive process suites' ||
      !sameJson(acceptance['source'], source) ||
      !sameJson(record['source'], source)) {
    _fail('Native acceptance fields or source differ');
  }
  _object(acceptance['source_suite']);
  final provenance = _object(acceptance['fixtures']);
  final fixtureFile = _one(artifact, 'acceptance-fixtures.json');
  verifiedBytes(fixtureFile, provenance['sha256']);
  final fixture = _object(readRecord(fixtureFile));
  if (!sameJson(fixture, provenance['manifest']) ||
      fixture['target'] != target ||
      !sameJson(fixture['source'], source) ||
      fixture['schema_version'] is! int ||
      fixture['schema_version'] != 1)
    _fail('Prepared fixture identity differs');
  final pins = _object(fixture['pins']);
  final flutter = _object(pins['flutter']),
      nodePin = _object(pins['wrong_node']);
  final git = _object(pins['git']);
  final flutterPin = fixtureFlutterPins[target]!;
  if (flutter['archive'] != flutterPin.archive ||
      flutter['sha256'] != flutterPin.sha256 ||
      flutter['version'] != fixtureFlutterVersion ||
      pins['dart'] != fixtureDartVersion ||
      nodePin['version'] != fixtureWrongNodeVersion ||
      nodePin['sha256'] != fixtureWrongNodePins[target]!.sha256 ||
      git['url'] != fixtureGitUrl ||
      git['ref'] != fixtureGitRef ||
      pins['collection'] != fixtureCollectionVersion)
    _fail('Prepared fixture pins differ');
  final harness = absolute(acceptance['source_root']);
  final node = absolute(acceptance['node_path']);
  final output = absolute(acceptance['output_root']);
  final sdk = absolute(fixture['dart_sdk']);
  final wrongNode = absolute(fixture['wrong_node']);
  final pub = absolute(fixture['pub_fixture']);
  final gitFixture = absolute(fixture['git_fixture']);
  final flutterSdk = absolute(fixture['flutter_sdk']);
  final flutterFixture = absolute(fixture['flutter_fixture']);
  if (!sameEvidencePath(harness, absolute(record['source_root']), paths) ||
      !sameJson(record['node'], [
        'v24.21.0',
        {
          'linux-x64': 'linux',
          'macos-arm64': 'darwin',
          'windows-x64': 'win32',
        }[target],
        target == 'macos-arm64' ? 'arm64' : 'x64',
      ])) {
    _fail('Native harness or runtime metadata differs');
  }
  final readiness = _object(fixture['readiness']);
  const prepared = {
    'pub/hosted',
    'pub/path',
    'pub/workspace',
    'git-fixture',
    'flutter-fixture',
  };
  const files = {
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
  };
  if (readiness.length != prepared.length ||
      !prepared.every(readiness.containsKey)) {
    _fail('Mandatory fixture preparation inventory differs');
  }
  for (final name in prepared) {
    final hashes = _object(readiness[name]);
    if (hashes.length != files.length ||
        !files.every(hashes.containsKey) ||
        hashes.values.any(
          (value) =>
              value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value),
        )) {
      _fail('Mandatory fixture preparation is incomplete');
    }
  }
  final environment = _object(fixture['environment']);
  if (environment.values.any((value) => value is! String) ||
      !sameEvidencePath(
        absolute(environment['ARCHWAY_PUB_GIT_FIXTURE']),
        gitFixture,
        paths,
      ) ||
      !sameEvidencePath(
        absolute(environment['ARCHWAY_FLUTTER_FIXTURE']),
        flutterFixture,
        paths,
      )) {
    _fail('Mandatory fixture environment differs');
  }
  final binary = paths.join(
    executed,
    'bin',
    target as String,
    windows ? 'archway.exe' : 'archway',
  );
  final dart = paths.join(sdk, 'bin', windows ? 'dart.exe' : 'dart');
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
    'runtime_preflight': [node, wrongNode, sdk],
    'native_asset': [],
    'native_abi': [],
    'native_fault': [],
    'package_provenance': [
      harness,
      pub,
      gitFixture,
      paths.join(output, 'package-provenance'),
    ],
    'dart_flutter': [flutterSdk, flutterFixture],
  };
  final suites = acceptance['suites'];
  if (suites is! List || suites.length != arguments.length)
    _fail('Expected exact 18-suite inventory');
  var index = 0;
  for (final entry in arguments.entries) {
    validateExecution(
      suites[index++],
      [
        dart,
        '--suppress-analytics',
        'run',
        paths.join(harness, 'test', '${entry.key}_process_smoke.dart'),
        binary,
        ...entry.value,
      ],
      Directory(p.join(report.parent.path, 'acceptance')),
      paths,
      suite: entry.key,
    );
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) _fail('Expected evidence object');
  return value;
}

Never _fail(String message) => throw FormatException(message);

File _one(Directory root, String name) {
  File? found;
  for (final entry in root.listSync(recursive: true, followLinks: false)) {
    if (p.basename(entry.path) != name) continue;
    if (found != null) _fail('Expected one original fixture manifest');
    found = File(entry.path);
  }
  if (found == null) _fail('Missing original fixture manifest');
  return found;
}
