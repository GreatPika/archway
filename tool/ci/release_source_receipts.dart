// Bind source-test proof to tracked checkout bytes and original reporter events.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import 'native_source_report.dart';
import 'release_execution_receipts.dart';

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected source receipt object');
  }
  return value;
}

String _string(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const FormatException('Expected source receipt path');
  }
  return value;
}

Future<List<String>> _tracked(Directory repository) async {
  final arguments = ['-C', repository.path, 'ls-files', '-z'];
  final child = await Process.start('git', arguments);
  final stdout = child.stdout.fold<List<int>>(
    [],
    (all, part) => all..addAll(part),
  );
  final stderr = child.stderr.transform(utf8.decoder).join();
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final results = await Future.wait<Object>([exit, stdout, stderr])
        .timeout(const Duration(seconds: 30));
    if (results[0] != 0) {
      throw ProcessException(
        'git',
        arguments,
        results[2] as String,
        results[0] as int,
      );
    }
    return utf8
        .decode(results[1] as List<int>)
        .split('\u0000')
        .where((name) => name.isNotEmpty)
        .toList();
  } finally {
    if (!exited) {
      child.kill(ProcessSignal.sigkill);
      await exit.timeout(const Duration(seconds: 5));
    }
  }
}

Future<void> validateSource(
  Map<String, dynamic> proof,
  File report,
  Map<String, dynamic> nativeManifest,
  Directory repository,
) async {
  final acceptance = _object(proof['acceptance']);
  final source = _object(acceptance['source_suite']);
  final identity = _object(proof['source']);
  final target = _string(proof['target']);
  if (!sourceTargets.contains(target) ||
      !sameJson(source['source'], identity) ||
      source['target'] != target ||
      !sameJson(nativeManifest['source'], identity) ||
      nativeManifest['target'] != target) {
    throw const FormatException('Source-suite/archive identity differs');
  }
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  final fixtures = _object(_object(acceptance['fixtures'])['manifest']);
  final dart = paths.join(
    _string(fixtures['dart_sdk']),
    'bin',
    target == 'windows-x64' ? 'dart.exe' : 'dart',
  );
  final snapshot = _string(source['snapshot_root']);
  if (!paths.isAbsolute(snapshot) ||
      (target == 'windows-x64' &&
          !RegExp(r'^(?:[a-zA-Z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))')
              .hasMatch(snapshot)) ||
      sameEvidencePath(snapshot, _string(proof['source_root']), paths) ||
      !sameEvidencePath(_string(source['dart']), dart, paths) ||
      source['snapshot_manifest'] != 'source-files.json') {
    throw const FormatException(
      'Source-suite snapshot or Dart selection differs',
    );
  }
  final environment = _object(fixtures['environment']);
  final readiness = _object(fixtures['readiness']);
  for (final entry in const {
    'git_fixture': ('git-fixture', 'ARCHWAY_PUB_GIT_FIXTURE'),
    'flutter_fixture': ('flutter-fixture', 'ARCHWAY_FLUTTER_FIXTURE'),
  }.entries) {
    if (!sameEvidencePath(
      _string(environment[entry.value.$2]),
      _string(fixtures[entry.key]),
      paths,
    )) {
      throw const FormatException(
        'Mandatory source fixture environment differs',
      );
    }
    final prepared = _object(readiness[entry.value.$1]);
    const names = {
      'pubspec.yaml',
      'pubspec.lock',
      '.dart_tool/package_config.json',
    };
    if (prepared.length != names.length || !names.every(prepared.containsKey)) {
      throw const FormatException(
        'Mandatory Git/Flutter fixture preparation is incomplete',
      );
    }
    if (prepared.values.any(
      (value) => value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value),
    )) {
      throw const FormatException(
        'Mandatory source fixture readiness hash is malformed',
      );
    }
  }
  final directory = Directory(p.join(report.parent.path, 'acceptance'));
  final snapshotFile = File(p.join(directory.path, 'source-files.json'));
  final saved = decodeEvidenceJson(
    utf8.decode(
      verifiedBytes(snapshotFile, source['snapshot_manifest_sha256']),
    ),
  );
  final current = <String, String>{};
  for (final name in await _tracked(repository)) {
    current[name] = sha256
        .convert(readOrdinaryBytes(File(p.join(repository.path, name))))
        .toString();
  }
  if (!sameJson(saved, current)) {
    throw const FormatException(
      'Source snapshot manifest differs from exact tracked checkout',
    );
  }
  final assets = <String, Object?>{};
  for (final entry in _object(nativeManifest['files']).entries) {
    if (entry.key.startsWith('assets/typescript/vendor/') ||
        entry.key.startsWith('native/$target/')) {
      assets[entry.key] = _object(entry.value)['sha256'];
    }
  }
  if (assets.isEmpty || !sameJson(source['assets'], assets)) {
    throw const FormatException(
      'Source-suite assets differ from verified native archive bytes',
    );
  }
  validateExecution(
    source['preparation'],
    [dart, '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
    directory,
    paths,
    suite: 'source-pub-get',
  );
  final logs = validateExecution(
    source['execution'],
    [dart, 'test', '--reporter=json'],
    directory,
    paths,
    suite: 'source-tests',
    expectedTimeout: 900,
  );
  final events = const LineSplitter()
      .convert(utf8.decode(logs['stdout']!))
      .map((line) => _object(decodeEvidenceJson(line)));
  final expected = current.keys
      .where((name) => name.startsWith('test/') && name.endsWith('_test.dart'))
      .toSet();
  final observed = summarizeTests(events, expected, target);
  if (expected.isEmpty || !sameJson(observed, source['tests'])) {
    throw const FormatException(
      'Source test inventory/results/OS skip summary differs from original JSON events',
    );
  }
}
