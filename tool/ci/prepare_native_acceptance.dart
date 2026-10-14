// Maintainer-only preparation of genuine fixtures, never called by inspection.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import '../../test/prepare_package_process_pub.dart';
import '../release/installation_identity.dart';
import 'native_fixture_pins.dart';
import 'preparation_process.dart';

Map<String, dynamic> flutterRecord(Map<String, dynamic> index, String target) {
  final pin = fixtureFlutterPins[target];
  if (pin == null) throw ArgumentError('Unsupported fixture target: $target');
  final matches = (index['releases'] as List)
      .whereType<Map<String, dynamic>>()
      .where(
        (r) =>
            r['version'] == fixtureFlutterVersion &&
            r['channel'] == 'stable' &&
            r['dart_sdk_arch'] == target.split('-')[1],
      )
      .toList();
  if (matches.length != 1) {
    throw const FormatException('Missing or ambiguous official Flutter pin');
  }
  final record = matches.single;
  if (record['archive'] != pin.archive ||
      record['sha256'] != pin.sha256 ||
      record['dart_sdk_version'] != fixtureDartVersion) {
    throw const FormatException(
      'Official Flutter metadata differs from reviewed pins',
    );
  }
  return record;
}

Map<String, String> preparationEnvironment(
  Directory root,
  String dart,
  String flutter, {
  required String git,
  Map<String, String>? inherited,
}) {
  final parent = inherited ?? Platform.environment;
  String fresh(String name) {
    final path = p.join(root.path, name);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('Preparation directory already exists', path);
    }
    Directory(path).createSync();
    return path;
  }

  final home = fresh('home'),
      cache = fresh('pub-cache'),
      hooks = fresh('empty-hooks');
  final config = File(p.join(root.path, 'empty-gitconfig'))
    ..createSync(exclusive: true);
  const retained = {
    'systemroot',
    'windir',
    'comspec',
    'pathext',
    'temp',
    'tmp',
    'http_proxy',
    'https_proxy',
    'no_proxy',
  };
  // Source acceptance includes native assembly and archive extraction. Keep
  // their PowerShell prerequisite without restoring the ambient tool search path.
  String? powerShell;
  if (Platform.isWindows) {
    final path = parent.entries
        .where((entry) => entry.key.toLowerCase() == 'path')
        .map((entry) => entry.value)
        .firstOrNull;
    for (final directory in (path ?? '').split(';')) {
      if (directory.isEmpty) continue;
      final candidate = File(p.join(directory, 'pwsh.exe'));
      if (candidate.existsSync()) {
        powerShell = candidate.resolveSymbolicLinksSync();
        break;
      }
    }
    if (powerShell == null) {
      throw StateError('Real PowerShell executable required');
    }
  }
  final paths = [
    p.dirname(dart),
    p.dirname(git),
    if (powerShell != null) p.dirname(powerShell),
    if (Platform.isWindows)
      p.join(
        parent.entries
            .firstWhere((e) => e.key.toLowerCase() == 'systemroot')
            .value,
        'System32',
      )
    else ...[
      '/usr/bin',
      '/bin',
    ],
  ];
  return {
    for (final entry in parent.entries)
      if (retained.contains(entry.key.toLowerCase())) entry.key: entry.value,
    'HOME': home,
    'USERPROFILE': home,
    'XDG_CONFIG_HOME': p.join(home, '.config'),
    'XDG_CACHE_HOME': p.join(home, '.cache'),
    'PUB_CACHE': cache,
    'PUB_HOSTED_URL': 'https://pub.dev',
    'PATH': paths.join(Platform.isWindows ? ';' : ':'),
    'FLUTTER_ROOT': flutter,
    'FLUTTER_SDK': flutter,
    'DART_SUPPRESS_ANALYTICS': 'true',
    'DASH__SUPPRESS_ANALYTICS': 'true',
    'FLUTTER_SUPPRESS_ANALYTICS': 'true',
    'CI': 'true',
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': config.path,
    'GIT_CONFIG_COUNT': '1',
    'GIT_CONFIG_KEY_0': 'core.hooksPath',
    'GIT_CONFIG_VALUE_0': hooks,
    'GIT_TERMINAL_PROMPT': '0',
  };
}

Future<String> fixtureSha(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> downloadFixture(
  Uri url,
  File path, {
  String? expected,
  Future<void> Function(Duration) delay = Future<void>.delayed,
  int maxBytes = 4 * 1024 * 1024 * 1024,
}) async {
  const timeout = Duration(seconds: 180);
  for (var attempt = 0; attempt < 3; attempt++) {
    final client = HttpClient()..connectionTimeout = timeout;
    client.findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
    var retry = false;
    try {
      final request = await client.getUrl(url).timeout(timeout);
      // All production URLs name official sources directly; fail closed on redirects.
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        if (![502, 503, 504].contains(response.statusCode) || attempt == 2) {
          throw HttpException('HTTP ${response.statusCode}', uri: url);
        }
        retry = true;
      } else {
        if (response.contentLength > maxBytes)
          throw const FormatException('Download exceeds byte limit');
        final output = path.openSync(mode: FileMode.write);
        try {
          var size = 0;
          await for (final bytes in response.timeout(timeout)) {
            size += bytes.length;
            if (size > maxBytes)
              throw const FormatException('Download exceeds byte limit');
            output.writeFromSync(bytes);
          }
        } finally {
          output.closeSync();
        }
        if (expected != null && await fixtureSha(path) != expected) {
          throw FormatException(
            'Archive checksum mismatch: ${p.basename(path.path)}',
          );
        }
        return;
      }
    } catch (_) {
      if (path.existsSync()) path.deleteSync();
      rethrow;
    } finally {
      client.close(force: true);
    }
    if (retry) {
      if (path.existsSync()) path.deleteSync();
      await delay(Duration(seconds: attempt + 1));
    }
  }
}

Future<Map<String, Map<String, String>>> fixtureReadiness(
  Directory root,
) async {
  final evidence = <String, Map<String, String>>{};
  for (final name in [
    'pub/hosted',
    'pub/path',
    'pub/workspace',
    'git-fixture',
    'flutter-fixture',
  ]) {
    evidence[name] = {
      for (final file in [
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
      ])
        file: await fixtureSha(File(p.join(root.path, name, file))),
    };
    final config = jsonDecode(
      File(p.join(root.path, name, '.dart_tool/package_config.json'))
          .readAsStringSync(),
    );
    if (config['configVersion'] != 2 ||
        config['generatorVersion'] != fixtureDartVersion) {
      throw FormatException('Invalid prepared package config: $name');
    }
  }
  return evidence;
}

const flutterBase =
    'https://storage.googleapis.com/flutter_infra_release/releases/';
const wrongNodeBase = 'https://nodejs.org/dist/v$fixtureWrongNodeVersion/';
String wrongNodeName(String target) =>
    'node-v$fixtureWrongNodeVersion-${fixtureWrongNodePins[target]!.archive}';
String wrongNodePath(Directory root, String target, {p.Context? paths}) =>
    (paths ?? p.context).join(
      root.path,
      wrongNodeName(target).replaceFirst(RegExp(r'\.(tar\.gz|zip)$'), ''),
      target == 'windows-x64' ? 'node.exe' : 'bin/node',
    );

Map<String, Object?> nativeFixtureManifest({
  required Directory root,
  required String target,
  required Map<String, Object?> source,
  required Map<String, String> environment,
  required Map<String, dynamic> flutter,
  required String gitPubspecSha,
  required Map<String, Map<String, String>> readiness,
  p.Context? paths,
}) => {
  'schema_version': 1,
  'source': source,
  'target': target,
  'dart_sdk': (paths ?? p.context).join(
    root.path,
    'flutter',
    'bin',
    'cache',
    'dart-sdk',
  ),
  'wrong_node': wrongNodePath(root, target, paths: paths),
  'pub_fixture': (paths ?? p.context).join(root.path, 'pub'),
  'git_fixture': (paths ?? p.context).join(root.path, 'git-fixture'),
  'flutter_sdk': (paths ?? p.context).join(root.path, 'flutter'),
  'flutter_fixture': (paths ?? p.context).join(root.path, 'flutter-fixture'),
  'environment': {
    for (final e in environment.entries)
      if (!{
        'http_proxy',
        'https_proxy',
        'no_proxy',
      }.contains(e.key.toLowerCase()))
        e.key: e.value,
  },
  'pins': {
    'flutter': {
      'index_url': '${flutterBase}releases_${target.split('-')[0]}.json',
      ...flutter,
    },
    'dart': fixtureDartVersion,
    'wrong_node': {
      'version': fixtureWrongNodeVersion,
      'url': '$wrongNodeBase${wrongNodeName(target)}',
      'sha256': fixtureWrongNodePins[target]!.sha256,
    },
    'git': {
      'url': fixtureGitUrl,
      'ref': fixtureGitRef,
      'path': 'pkgs/path',
      'cache_origin': fixtureGitUrl,
      'package_pubspec_sha256': gitPubspecSha,
    },
    'collection': fixtureCollectionVersion,
  },
  'readiness': readiness,
};

List<String> officialExtractionCommand(
  String archive,
  String root,
  String target,
  Map<String, String> environment,
) {
  if (!archive.endsWith('.zip') &&
      !archive.endsWith('.tar.xz') &&
      !archive.endsWith('.tar.gz')) {
    throw ArgumentError('Unsupported official archive format');
  }
  if (target == 'windows-x64') {
    final systemRoot = environment.entries
        .firstWhere((e) => e.key.toLowerCase() == 'systemroot')
        .value;
    return [
      p.windows.join(systemRoot, 'System32', 'tar.exe'),
      '-xf',
      archive,
      '-C',
      root,
    ];
  }
  if (archive.endsWith('.zip'))
    return ['/usr/bin/unzip', '-q', archive, '-d', root];
  return ['/usr/bin/tar', '-xf', archive, '-C', root];
}

String preparationGit() {
  final path = Platform.environment.entries
      .firstWhere((e) => e.key.toLowerCase() == 'path')
      .value;
  for (final entry in path.split(Platform.isWindows ? ';' : ':')) {
    if (entry.isEmpty) continue;
    final file = File(p.join(entry, Platform.isWindows ? 'git.exe' : 'git'));
    if (file.existsSync() &&
        (Platform.isWindows || posix.access(file.path, posix.X_OK) == 0)) {
      return file.resolveSymbolicLinksSync();
    }
  }
  throw StateError('Real Git executable required');
}

Future<Map<String, Object?>> prepareNativeFixtures({
  required String target,
  required Directory output,
  required Directory repository,
  File? flutterArchive,
}) async {
  final host = switch (Abi.current()) {
    Abi.linuxX64 => 'linux-x64',
    Abi.macosArm64 => 'macos-arm64',
    Abi.windowsX64 => 'windows-x64',
    _ => 'unsupported',
  };
  if (!fixtureFlutterPins.containsKey(target) || target != host) {
    throw ArgumentError('Fixture target differs from actual host');
  }
  final source = await sourceIdentity(repository);
  final root = output.absolute;
  if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException('Fixture output already exists', root.path);
  }
  root.createSync(recursive: true);
  final canonical = Directory(root.resolveSymbolicLinksSync());
  String path(String name) => p.joinAll([canonical.path, ...name.split('/')]);
  final flutter = path('flutter'),
      dart = path(
        'flutter/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      );
  final git = preparationGit();
  final env = preparationEnvironment(canonical, dart, flutter, git: git);
  Future<String> run(List<String> command, String log, {String? cwd}) =>
      runPreparation(
        command,
        env,
        File(path('logs/$log.log')),
        cwd: cwd == null ? canonical : Directory(cwd),
      );
  Future<void> unpack(File archive, String digest, String log) async {
    if (await fixtureSha(archive) != digest)
      throw const FormatException('Official archive checksum mismatch');
    await runPreparation(
      officialExtractionCommand(archive.path, canonical.path, target, env),
      env,
      File(path('logs/$log.log')),
      cwd: canonical,
      timeout: const Duration(seconds: 300),
    );
  }

  final index = File(path('flutter-index.json'));
  await downloadFixture(
    Uri.parse('${flutterBase}releases_${target.split('-')[0]}.json'),
    index,
    maxBytes: 16 * 1024 * 1024,
  );
  final record = flutterRecord(
    jsonDecode(index.readAsStringSync()) as Map<String, dynamic>,
    target,
  );
  final archive =
      flutterArchive?.absolute ??
      File(path(p.posix.basename(record['archive'] as String)));
  if (flutterArchive == null) {
    await downloadFixture(
      Uri.parse('$flutterBase${record['archive']}'),
      archive,
      expected: record['sha256'] as String,
    );
  }
  await unpack(archive, record['sha256'] as String, 'flutter-extraction');
  if (!(await run([
    dart,
    '--version',
  ], 'dart-version')).startsWith('Dart SDK version: $fixtureDartVersion ')) {
    throw const FormatException('Wrong embedded Dart runtime');
  }
  final sdk = jsonDecode(
    File(path('flutter/bin/cache/flutter.version.json')).readAsStringSync(),
  );
  if (sdk['frameworkVersion'] != fixtureFlutterVersion ||
      sdk['dartSdkVersion'] != fixtureDartVersion) {
    throw const FormatException(
      'Extracted Flutter SDK metadata differs from pins',
    );
  }
  final sums = File(path('node-shasums.txt'));
  await downloadFixture(
    Uri.parse('${wrongNodeBase}SHASUMS256.txt'),
    sums,
    maxBytes: 1024 * 1024,
  );
  final nodeName = wrongNodeName(target),
      nodePin = fixtureWrongNodePins[target]!;
  final matches = const LineSplitter()
      .convert(sums.readAsStringSync())
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((r) => r.length == 2 && r[1] == nodeName)
      .map((r) => r[0])
      .toList();
  if (matches.length != 1 || matches.single != nodePin.sha256) {
    throw const FormatException(
      'Official wrong-Node checksum differs from pin',
    );
  }
  final nodeArchive = File(path(nodeName));
  await downloadFixture(
    Uri.parse('$wrongNodeBase$nodeName'),
    nodeArchive,
    expected: nodePin.sha256,
  );
  await unpack(nodeArchive, nodePin.sha256, 'node-extraction');
  if (await run([
        wrongNodePath(canonical, target),
        '--version',
      ], 'wrong-node-version') !=
      'v$fixtureWrongNodeVersion') {
    throw const FormatException('Wrong negative-control Node runtime');
  }
  await run([
    dart,
    '--suppress-analytics',
    'pub',
    'cache',
    'add',
    'collection',
    '--version',
    fixtureCollectionVersion,
  ], 'collection-cache');
  await preparePubFixtures(Directory(path('pub')), dart, env);
  const spec = 'name: fixture\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\n';
  writePreparation(
    File(path('git-fixture/pubspec.yaml')),
    '${spec}dependencies:\n  path:\n    git:\n      url: $fixtureGitUrl\n      ref: $fixtureGitRef\n      path: pkgs/path\n',
  );
  writePreparation(
    File(path('flutter-fixture/pubspec.yaml')),
    '${spec.replaceFirst('name: fixture', 'name: flutter_fixture')}dependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
  );
  for (final name in ['git-fixture', 'flutter-fixture']) {
    await run(
      [dart, '--suppress-analytics', 'pub', 'get'],
      name,
      cwd: path(name),
    );
  }
  final config = jsonDecode(
    File(path('git-fixture/.dart_tool/package_config.json')).readAsStringSync(),
  );
  final uri = Uri.parse(
    (config['packages'] as List).singleWhere(
          (package) => package['name'] == 'path',
        )['rootUri']
        as String,
  );
  if (uri.scheme != 'file' || !uri.hasAbsolutePath)
    throw const FormatException('Git package cache origin must be absolute');
  final package = Directory.fromUri(uri).resolveSymbolicLinksSync();
  if (!p.equals(package, path('pub-cache/git/core-$fixtureGitRef/pkgs/path'))) {
    throw const FormatException(
      'Git package resolved outside pinned isolated cache',
    );
  }
  final checkout = p.dirname(p.dirname(package));
  final head = await run([
    git,
    '-C',
    checkout,
    'rev-parse',
    'HEAD',
  ], 'git-head');
  final origin = await run([
    git,
    '-C',
    checkout,
    'remote',
    'get-url',
    'origin',
  ], 'git-origin');
  final upstream = await run([
    git,
    '-C',
    origin,
    'remote',
    'get-url',
    'origin',
  ], 'git-cache-origin');
  if (head != fixtureGitRef || upstream != fixtureGitUrl)
    throw const FormatException('Git checkout or upstream differs from pin');
  final lock = File(path('git-fixture/pubspec.lock')).readAsStringSync();
  if (![
    fixtureGitUrl,
    fixtureGitRef,
    'pkgs/path',
    'source: git',
  ].every(lock.contains)) {
    throw const FormatException('Git lock does not preserve pinned provenance');
  }
  env.addAll({
    'ARCHWAY_PUB_GIT_FIXTURE': path('git-fixture'),
    'ARCHWAY_FLUTTER_FIXTURE': path('flutter-fixture'),
  });
  if (jsonEncode(await sourceIdentity(repository)) != jsonEncode(source))
    throw StateError('Source changed during native fixture preparation');
  final manifest = nativeFixtureManifest(
    root: canonical,
    target: target,
    source: source,
    environment: env,
    flutter: record,
    gitPubspecSha: await fixtureSha(File(p.join(package, 'pubspec.yaml'))),
    readiness: await fixtureReadiness(canonical),
  );
  writePreparation(
    File(path('acceptance-fixtures.json')),
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  return manifest;
}

Future<void> main(List<String> args) async {
  try {
    final options = <String, String>{};
    for (var i = 0; i < args.length; i += 2) {
      if (!['--target', '--output', '--flutter-archive'].contains(args[i]) ||
          i + 1 == args.length ||
          options.containsKey(args[i])) {
        throw ArgumentError(
          'Usage: --target TARGET --output NEW_DIRECTORY [--flutter-archive OFFICIAL_ARCHIVE]',
        );
      }
      options[args[i]] = args[i + 1];
    }
    if (!options.containsKey('--target') || !options.containsKey('--output'))
      throw ArgumentError('--target and --output are required');
    final manifest = await prepareNativeFixtures(
      target: options['--target']!,
      output: Directory(options['--output']!),
      repository: File.fromUri(Platform.script).parent.parent.parent,
      flutterArchive: options['--flutter-archive'] == null
          ? null
          : File(options['--flutter-archive']!),
    );
    stdout.writeln(
      p.join(
        p.dirname(manifest['pub_fixture'] as String),
        'acceptance-fixtures.json',
      ),
    );
  } catch (error) {
    stderr.writeln('Native acceptance preparation failed: $error');
    exitCode = 1;
  }
}
