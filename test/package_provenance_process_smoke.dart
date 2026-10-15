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
import 'support/node_package_fixtures.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void write(String path, String text) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

String policy(String adapter, String directory, [String packageRoots = './']) {
  final config = adapter == 'typescript'
      ? 'tsconfig: tsconfig.json'
      : 'package_roots: [$packageRoots]';
  return '''version: 1
projects:
  - {id: app, adapter: $adapter, $config}
scope: [$directory/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [$directory/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [$directory/core/], allows: [], public: []}
''';
}

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

  final node = Directory(p.join(fixtures.path, 'node'))..createSync();
  for (final archive in ['prepared.tar.gz', 'addon.tar.gz']) {
    await extractNodeFixture(
      File(p.join(repo, 'test/fixtures/node-packages', archive)),
      node,
    );
  }
  String ts(String name, String specifier, {bool independent = true}) {
    final root = p.join(node.path, name);
    final src = Directory(p.join(root, 'src'));
    if (src.existsSync()) src.deleteSync(recursive: true);
    write(p.join(root, 'architecture.yaml'), policy('typescript', 'src'));
    write(
      p.join(root, 'src/app/main.ts'),
      "import '$specifier';\n"
      '${independent ? "import \'../core/private.js\';\n" : ""}',
    );
    write(p.join(root, 'src/core/private.ts'), 'export const value = 1;\n');
    return root;
  }

  for (final (name, specifier, kind, identity) in [
    ('npm-v3-small', 'ansi-regex', 'external', 'npm:ansi-regex@6.1.0'),
    ('pnpm-registry', 'ansi-regex', 'external', 'pnpm:ansi-regex@6.1.0'),
    ('npm-tarball', 'ansi-regex', 'external', 'npm:ansi-regex@6.1.0'),
    ('pnpm-git', 'ansi-regex', 'external', null),
    (
      'pnpm-peer',
      'react-dom/client',
      'external',
      'pnpm:@types/react-dom@19.0.4(@types/react@19.0.12)',
    ),
    ('npm-workspace', 'archway-local-types', 'local', null),
    ('pnpm-injected', 'archway-local-types', 'local', null),
    ('npm-file', 'archway-outside-types', 'local', null),
    ('npm-path', 'archway-outside-types', 'local', null),
    ('pnpm-path', 'archway-outside-types', 'local', null),
  ]) {
    final value = await invoke(
      name,
      ts(name, specifier),
      kind,
      specifier,
      identity: identity,
    );
    if (name.endsWith('-path')) {
      check(
        (value['payload']['violations'] as List).any(
          (v) => v['code'] == 'LOCAL_TARGET_OUTSIDE_SCOPE',
        ),
        '$name: outside scope',
      );
      check(
        (value['payload']['facts']['edges'] as List).firstWhere(
              (e) => e['specifier'] == specifier,
            )['resolution']['path'] ==
            null,
        '$name: outside path exposed',
      );
    }
  }
  var root = ts('npm-v2', 'ansi-regex', independent: false);
  await invoke(
    'npm-clean-success',
    root,
    'external',
    'ansi-regex',
    code: 0,
    violation: null,
  );
  root = ts('npm-shrinkwrap', 'ansi-regex');
  write(p.join(root, 'package-lock.json'), '{"lockfileVersion": 99}');
  await invoke('npm-shrinkwrap-precedence', root, 'external', 'ansi-regex');
  root = p.join(node.path, 'pnpm-registry');
  final saved = {
    for (final name in [
      'package.json',
      'pnpm-lock.yaml',
      'node_modules/.pnpm/lock.yaml',
    ])
      name: File(p.join(root, name)).readAsBytesSync(),
  };
  const source = 'https://registry.npmjs.org/ansi-regex/-/ansi-regex-6.1.0.tgz';
  final manifest =
      jsonDecode(File(p.join(root, 'package.json')).readAsStringSync()) as Map;
  manifest['dependencies']['ansi-regex'] = source;
  write(p.join(root, 'package.json'), jsonEncode(manifest));
  for (final name in ['pnpm-lock.yaml', 'node_modules/.pnpm/lock.yaml']) {
    final lock = File(p.join(root, name));
    lock.writeAsStringSync(
      lock
          .readAsStringSync()
          .replaceFirst('specifier: 6.1.0', 'specifier: "$source"')
          .replaceFirst(
            'resolution: {integrity:',
            'resolution: {tarball: "https://example.org/contradictory.tgz", integrity:',
          ),
    );
  }
  await invoke(
    'pnpm-explicit-tarball-conflict',
    root,
    'unresolved',
    'ansi-regex',
    code: 2,
  );
  for (final entry in saved.entries) {
    File(p.join(root, entry.key)).writeAsBytesSync(entry.value);
  }
  for (final (name, lock) in [
    ('npm-v3-small', 'package-lock.json'),
    ('pnpm-registry', 'pnpm-lock.yaml'),
  ]) {
    root = p.join(node.path, name);
    File(p.join(root, lock)).deleteSync();
    await invoke(
      '$name-missing-lock',
      root,
      'unresolved',
      'ansi-regex',
      code: 2,
    );
  }
  for (final name in ['npm-alias', 'pnpm-alias']) {
    root = ts(name, 'fixture-alias');
    final file = File(p.join(root, 'node_modules/fixture-alias/package.json'));
    final value = jsonDecode(file.readAsStringSync()) as Map;
    value['name'] = 'contradictory-name';
    file.deleteSync(); // Detach copied hardlinks before mutation.
    write(file.path, jsonEncode(value));
    await invoke(
      '$name-conflict',
      root,
      'unresolved',
      'fixture-alias',
      code: 2,
    );
  }

  copyTree(Directory(pub), Directory(p.join(fixtures.path, 'pub')));
  String dart(String name, String specifier) {
    final root = p.join(fixtures.path, 'pub', name);
    write(p.join(root, 'architecture.yaml'), policy('dart', 'lib'));
    write(
      p.join(root, 'lib/app/main.dart'),
      "import '$specifier';\nimport '../core/private.dart';\nimport 'dart:io';\n",
    );
    write(p.join(root, 'lib/core/private.dart'), 'class Value {}\n');
    return root;
  }

  root = dart('hosted', 'package:collection/collection.dart');
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
    policy(
      'dart',
      'lib',
    ).replaceFirst('exclude: []', 'exclude: [lib/app/vendor/]'),
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
    policy('dart', 'packages', 'packages/app, packages/core'),
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
  stdout.writeln(
    '${results.length} package provenance AOT process checks passed; host-only evidence.',
  );
}
