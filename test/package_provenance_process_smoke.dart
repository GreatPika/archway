// Real AOT package provenance over prepared manager outputs. No preparation here.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'dart_check_process_smoke.dart' show copyTree;
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void write(String path, String text) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

String policy(String directory, [String packageRoots = './']) =>
    '''version: 1
projects:
  - {id: app, adapter: dart, package_roots: [$packageRoots]}
scope: [$directory/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [$directory/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [$directory/core/], allows: [], public: []}
''';

Map<String, String> snapshot(Directory root) => {
  for (final entity in root.listSync(recursive: true, followLinks: false))
    if (entity is Link)
      p.relative(entity.path, from: root.path): 'link:${entity.targetSync()}'
    else if (entity is File)
      p.relative(entity.path, from: root.path): sha256
          .convert(entity.readAsBytesSync())
          .toString(),
};

Future<void> main(List<String> args) async {
  if (args.length != 5) {
    stderr.writeln(
      'Usage: dart run test/package_provenance_process_smoke.dart '
      '<executable> <repository> <prepared pub> <prepared Git> <output>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(args[0]);
  final repo = Directory(args[1]).resolveSymbolicLinksSync();
  final pub = Directory(args[2]).resolveSymbolicLinksSync();
  final git = Directory(args[3]).resolveSymbolicLinksSync();
  final output = Directory(p.absolute(args[4]))..createSync(recursive: true);
  final fixtures = Directory(p.join(output.path, 'fixtures'));
  check(!fixtures.existsSync(), 'Fixture output must be fresh');
  fixtures.createSync();
  final staged = stageInstallation(
    executable,
    Directory(p.join(output.path, 'installation')),
  );
  final schema = ContractSchema(
    jsonDecode(
      File(p.join(repo, 'contracts/json/public-result.schema.json'))
          .readAsStringSync(),
    ),
  );
  final results = <Map<String, Object?>>[];

  Future<Map> invoke(
    String name,
    String root,
    String kind,
    String specifier, {
    int code = 1,
    String? violation = 'DEPENDENCY_NOT_ALLOWED',
    String? identity,
  }) async {
    final before = snapshot(Directory(root));
    final result = await runNativeProcess(
      [staged.path, '--root', root, 'check'],
      workingDirectory: output.path,
      timeout: const Duration(seconds: 90),
    );
    File(p.join(output.path, '$name.stdout.json'))
        .writeAsBytesSync(result.stdout);
    File(p.join(output.path, '$name.stderr.txt'))
        .writeAsBytesSync(result.stderr);
    check(
      result.exitCode == code,
      '$name: exit ${result.exitCode}, '
      '${utf8.decode(result.stdout)} ${utf8.decode(result.stderr)}',
    );
    check(result.stderr.isEmpty, '$name: stderr ${result.stderr}');
    check(
      result.stdout.isNotEmpty &&
          result.stdout.last == 10 &&
          result.stdout.where((byte) => byte == 10).length == 1,
      '$name: JSON framing',
    );
    final value = jsonDecode(utf8.decode(result.stdout)) as Map;
    check(schema.errors(value).isEmpty, '$name: ${schema.errors(value)}');
    check(value['exit_code'] == code, '$name: public exit');
    check(
      value['status'] == {0: 'ok', 1: 'negative', 2: 'incomplete'}[code],
      '$name: status',
    );
    final payload = value['payload'] as Map;
    check(payload['input_identity']['rechecked'] == true, '$name: freshness');
    check(payload['analysis_complete'] == (code != 2), '$name: completeness');
    check(
      sameJson(payload['tool_errors'], []),
      '$name: ${payload['tool_errors']}',
    );
    final edges = payload['facts']['edges'] as List;
    final edge = edges.firstWhere((e) => e['specifier'] == specifier) as Map;
    check(edge['resolution']['kind'] == kind, '$name: $edge');
    if (identity != null)
      check(edge['resolution']['identity'] == identity, '$name: $edge');
    final codes = [for (final v in payload['violations']) v['code']];
    if (violation != null) {
      check(
        codes.contains(violation) && codes.contains('DEPENDENCY_NOT_ALLOWED'),
        '$name: $codes',
      );
    } else {
      check(codes.isEmpty, '$name: $codes');
    }
    if (code == 2) {
      check(
        (payload['unknowns'] as List).isNotEmpty,
        '$name: missing unknowns',
      );
      check(
        edges.any((e) => e['resolution']['kind'] == 'local'),
        '$name: independent local fact',
      );
    }
    check(
      sameJson(before, snapshot(Directory(root))),
      '$name: check wrote project inputs',
    );
    results.add({
      'case': name,
      'exit': code,
      'status': value['status'],
      'kind': kind,
      'violations': codes,
      'unknowns': [for (final u in payload['unknowns']) u['code']],
    });
    stdout.writeln('PASS $name: exit=$code kind=$kind');
    write(
      p.join(output.path, 'summary.json'),
      '${const JsonEncoder.withIndent('  ').convert(results)}\n',
    );
    return value;
  }

  copyTree(Directory(pub), Directory(p.join(fixtures.path, 'pub')));
  String dart(String name, String specifier) {
    final root = p.join(fixtures.path, 'pub', name);
    write(p.join(root, 'architecture.yaml'), policy('lib'));
    write(
      p.join(root, 'lib/app/main.dart'),
      "import '$specifier';\nimport '../core/private.dart';\nimport 'dart:io';\n",
    );
    write(p.join(root, 'lib/core/private.dart'), 'class Value {}\n');
    return root;
  }

  var root = dart('hosted', 'package:collection/collection.dart');
  await invoke(
    'pub-hosted',
    root,
    'external',
    'package:collection/collection.dart',
  );
  final inside = p.join(fixtures.path, 'pub/hosted-inside');
  copyTree(Directory(root), Directory(inside));
  final config = jsonDecode(
    File(p.join(inside, '.dart_tool/package_config.json')).readAsStringSync(),
  ) as Map;
  final entry = (config['packages'] as List).firstWhere(
    (e) => e['name'] == 'collection',
  ) as Map;
  final uri = Uri.parse(entry['rootUri'] as String);
  check(
    uri.scheme == 'file' &&
        uri.hasAbsolutePath &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.userInfo.isEmpty &&
        !uri.hasPort,
    'Expected absolute package file URI',
  );
  final original = Directory.fromUri(uri);
  final vendor = Directory(p.join(inside, 'lib/app/vendor/collection'));
  vendor.parent.createSync(recursive: true);
  copyTree(original, vendor);
  for (final entity in vendor.listSync(recursive: true, followLinks: false)) {
    if (entity is File && p.basename(entity.path) == 'analysis_options.yaml')
      entity.writeAsStringSync('{}');
  }
  entry['rootUri'] = '../lib/app/vendor/collection/';
  write(p.join(inside, '.dart_tool/package_config.json'), jsonEncode(config));
  write(
    p.join(inside, 'architecture.yaml'),
    policy('lib').replaceFirst('exclude: []', 'exclude: [lib/app/vendor/]'),
  );
  await invoke(
    'pub-hosted-inside-root',
    inside,
    'external',
    'package:collection/collection.dart',
  );
  final spec = File(p.join(root, 'pubspec.yaml'));
  final originalSpec = spec.readAsStringSync();
  spec.writeAsStringSync(
    originalSpec.replaceFirst('collection: 1.19.1', 'collection: ^2.0.0'),
  );
  await invoke(
    'pub-version-conflict',
    root,
    'unresolved',
    'package:collection/collection.dart',
    code: 2,
  );
  spec.writeAsStringSync(originalSpec);
  File(p.join(root, 'pubspec.lock')).deleteSync();
  await invoke(
    'pub-missing-lock',
    root,
    'unresolved',
    'package:collection/collection.dart',
    code: 2,
  );
  root = dart('path', 'package:outside_pkg/value.dart');
  await invoke(
    'pub-outside-path',
    root,
    'local',
    'package:outside_pkg/value.dart',
    violation: 'LOCAL_TARGET_OUTSIDE_SCOPE',
  );
  root = p.join(fixtures.path, 'pub/workspace');
  write(
    p.join(root, 'architecture.yaml'),
    policy('packages', 'packages/app, packages/core'),
  );
  write(
    p.join(root, 'packages/app/lib/main.dart'),
    "import 'package:core/value.dart';\n",
  );
  await invoke(
    'pub-workspace-hosted-constraint',
    root,
    'local',
    'package:core/value.dart',
  );
  copyTree(Directory(git), Directory(p.join(fixtures.path, 'pub/git')));
  root = dart('git', 'package:path/path.dart');
  await invoke('pub-pinned-git', root, 'external', 'package:path/path.dart');
  check(results.length == 7, 'Expected all seven Dart provenance cases');
  stdout.writeln(
    '${results.length} package provenance AOT process checks passed; host-only evidence.',
  );
}
