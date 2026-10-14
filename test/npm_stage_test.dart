import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/release/installation_identity.dart';
import 'support/npm_stage_fixture.dart';

// Preserve the installed guide contract without requiring network access.
void verifyPackagedReadmeLinks(String readme, Directory repository) {
  final links = RegExp(r'\[[^\]]+\]\(([^)]+)\)').allMatches(readme);
  if (links.isEmpty) throw const FormatException('Packaged guide has no links');
  for (final match in links) {
    final link = match[1]!;
    final uri = Uri.parse(link);
    if (uri.scheme != 'https' || uri.authority != 'github.com')
      throw FormatException('Packaged guide link must use HTTPS GitHub', link);
    if (link == 'https://github.com/GreatPika/archway/releases') continue;
    const prefix = '/GreatPika/archway/blob/main/';
    if (!uri.path.startsWith(prefix))
      throw FormatException('Packaged guide link must name a repository file', link);
    final target = File(p.join(repository.path, uri.path.substring(prefix.length)));
    if (!target.existsSync())
      throw FormatException('Packaged guide target is missing', link);
    if (uri.fragment.isNotEmpty) {
      final anchors = RegExp(r'^#+ (.+)$', multiLine: true)
          .allMatches(target.readAsStringSync())
          .map((heading) => heading[1]!
              .toLowerCase()
              .replaceAll(RegExp(r'[^\p{L}\p{N}_ -]', unicode: true), '')
              .replaceAll(' ', '-'));
      if (!anchors.contains(uri.fragment))
        throw FormatException('Packaged guide heading is missing', link);
    }
  }
}

void main() {
  late Directory root, source;
  late Map<String, Object> identity;
  late File descriptor;
  final repository = Directory.current.path;
  setUp(() async {
    final fixture = await prepareNpmStageFixture();
    root = fixture.root;
    source = fixture.source;
    identity = fixture.identity;
    descriptor = fixture.descriptor;
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<ProcessResult> stage(
    String output, {
    bool ready = false,
    Map<String, String>? environment,
  }) => Process.run(
    Platform.resolvedExecutable,
    [
      p.join(repository, 'tool/npm/stage.dart'),
      '--source',
      source.path,
      '--descriptor',
      descriptor.path,
      '--expected-commit',
      identity['commit']! as String,
      '--output',
      p.join(root.path, output),
      if (ready) '--registry-ready',
    ],
    environment: environment,
    includeParentEnvironment: environment == null,
  );
  test('packaged npm guide refuses missing repository documents', () {
    expect(
      () => verifyPackagedReadmeLinks(
        '[Missing](https://github.com/GreatPika/archway/blob/main/missing.md)',
        root,
      ),
      throwsFormatException,
    );
  });
  test('packaged npm guide fragments must name document headings', () {
    File(p.join(root.path, 'guide.md'))
        .writeAsStringSync('# Guide\n\n## Installation & usage\n');
    const document = 'https://github.com/GreatPika/archway/blob/main/guide.md';
    expect(
      () => verifyPackagedReadmeLinks('[Guide]($document#installation--usage)', root),
      returnsNormally,
    );
    expect(
      () => verifyPackagedReadmeLinks('[Guide]($document#missing-heading)', root),
      throwsFormatException,
    );
  });
  test('packaged npm guide keeps its HTTPS repository link boundary', () {
    verifyPackagedReadmeLinks(
      '[Releases](https://github.com/GreatPika/archway/releases)',
      root,
    );
    for (final link in [
      'http://github.com/GreatPika/archway/releases',
      'https://example.invalid/GreatPika/archway/releases',
      'https://github.com/another/repository/blob/main/guide.md',
    ]) {
      expect(
        () => verifyPackagedReadmeLinks('[Guide]($link)', root),
        throwsFormatException,
        reason: link,
      );
    }
    expect(
      () => verifyPackagedReadmeLinks('Guide without documentation links', root),
      throwsFormatException,
    );
  });
  test('private thin stage binds canonical source and offline locked wrapper dependencies', () async {
    final environment = Map<String, String>.from(Platform.environment);
    final configured = await Process.run('npm', [
      '--offline',
      '--no-update-notifier',
      'config',
      'get',
      'cache',
    ], runInShell: Platform.isWindows);
    expect(configured.exitCode, 0, reason: '${configured.stderr}');
    final preparedCache = (configured.stdout as String).trim();
    environment.removeWhere(
      (key, _) => key.toLowerCase() == 'npm_config_cache',
    );
    final isolatedHome = Directory(p.join(root.path, 'empty npm home'))
      ..createSync();
    environment.removeWhere(
      (key, _) =>
          ['home', 'userprofile', 'localappdata'].contains(key.toLowerCase()),
    );
    environment.addAll({
      'HOME': isolatedHome.path,
      'USERPROFILE': isolatedHome.path,
      'LOCALAPPDATA': isolatedHome.path,
      'NpM_CoNfIg_CaChE': preparedCache,
    });
    final result = await stage('stage', environment: environment);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final package = Directory(p.join(root.path, 'stage/package'));
    final readme = File(p.join(package.path, 'README.md')).readAsStringSync();
    expect(
      readme,
      File(p.join(repository, 'tool/npm/README.md')).readAsStringSync(),
    );
    verifyPackagedReadmeLinks(readme, Directory(repository));
    final manifest = jsonDecode(
      File(p.join(package.path, 'package.json')).readAsStringSync(),
    ) as Map;
    expect(manifest['name'], 'archway-architecture-cli');
    expect(manifest['version'], '1.2.3');
    expect(manifest['private'], true);
    expect(manifest.containsKey('scripts'), false);
    expect(manifest.containsKey('optionalDependencies'), false);
    expect(manifest.containsKey('engines'), false);
    expect(manifest['dependencies'], {'tar': '7.5.22', 'yauzl': '3.4.0'});
    expect(
      File(p.join(package.path, 'acquisition.json')).readAsBytesSync(),
      descriptor.readAsBytesSync(),
    );
    for (final forbidden in ['native', 'assets', 'schemas', 'lib'])
      expect(Directory(p.join(package.path, forbidden)).existsSync(), false);
    final receipt = jsonDecode(
      File(p.join(root.path, 'stage/npm-stage.json')).readAsStringSync(),
    ) as Map;
    expect(receipt['source'], identity);
    expect(receipt['registry_ready'], false);
    const dependencies = {
      '@isaacs/fs-minipass': ('4.0.1', 'LICENSE'),
      'chownr': ('3.0.0', 'LICENSE.md'),
      'minipass': ('7.1.3', 'LICENSE.md'),
      'minizlib': ('3.1.0', 'LICENSE'),
      'pend': ('1.2.0', 'LICENSE'),
      'tar': ('7.5.22', 'LICENSE.md'),
      'yallist': ('5.0.0', 'LICENSE.md'),
      'yauzl': ('3.4.0', 'LICENSE'),
    };
    expect(
      (receipt['files'] as Map).keys.where(
        (name) =>
            RegExp(r'^node_modules/(?:@[^/]+/)?[^/]+/package\.json$')
                .hasMatch(name as String),
      ),
      unorderedEquals(
        dependencies.keys.map((name) => 'node_modules/$name/package.json'),
      ),
    );
    for (final entry in dependencies.entries) {
      final dependency = Directory(
        p.join(package.path, 'node_modules', entry.key),
      );
      expect(
        jsonDecode(
          File(p.join(dependency.path, 'package.json')).readAsStringSync(),
        )['version'],
        entry.value.$1,
      );
      final relative = 'node_modules/${entry.key}/${entry.value.$2}';
      final bytes = File(p.join(package.path, relative)).readAsBytesSync();
      expect(bytes, isNotEmpty);
      expect(
        receipt['files'][relative]['sha256'],
        sha256.convert(bytes).toString(),
      );
    }
    expect(
      (jsonDecode(descriptor.readAsStringSync())['targets'] as Map).keys,
      unorderedEquals(['linux-x64', 'macos-arm64', 'windows-x64']),
    );
    expect(await sourceIdentity(source), identity);
  });
  test('registry intent precedes inventory hashing and existing output is never replaced', () async {
    expect((await stage('ready', ready: true)).exitCode, 0);
    final rootStage = Directory(p.join(root.path, 'ready'));
    final manifest = jsonDecode(
      File(p.join(rootStage.path, 'package/package.json')).readAsStringSync(),
    ) as Map;
    final receipt = jsonDecode(
      File(p.join(rootStage.path, 'npm-stage.json')).readAsStringSync(),
    ) as Map;
    expect(manifest['private'], false);
    expect(receipt['registry_ready'], true);
    final bytes = File(p.join(rootStage.path, 'package/package.json'))
        .readAsBytesSync();
    expect(receipt['files']['package.json'], {
      'size': bytes.length,
      'mode': 0x1a4,
      'sha256': sha256.convert(bytes).toString(),
    });
    final before = File(p.join(rootStage.path, 'npm-stage.json'))
        .readAsBytesSync();
    final repeated = await stage('ready');
    expect(repeated.exitCode, 1);
    expect(repeated.stderr, contains('already exists'));
    expect(
      File(p.join(rootStage.path, 'npm-stage.json')).readAsBytesSync(),
      before,
    );
  });
  test('descriptor source, target, immutable URL and cache failure cannot create a stage', () async {
    final original = descriptor.readAsStringSync();
    for (final issue in ['source', 'targets', 'url']) {
      final changed = jsonDecode(original) as Map;
      if (issue == 'source') changed['source']['commit'] = 'f' * 40;
      if (issue == 'targets') (changed['targets'] as Map).remove('macos-arm64');
      if (issue == 'url')
        changed['targets']['linux-x64']['url'] = 'https://example.test/other';
      descriptor.writeAsStringSync(jsonEncode(changed));
      final result = await stage('rejected');
      expect(result.exitCode, 1, reason: issue);
      expect(
        result.stderr,
        contains(
          issue == 'source'
              ? 'source or version'
              : issue == 'targets'
              ? 'targets differ'
              : 'descriptor target',
        ),
      );
      expect(Directory(p.join(root.path, 'rejected')).existsSync(), false);
    }
    descriptor.writeAsStringSync(original);
    final emptyCacheEnvironment = Map<String, String>.from(Platform.environment)
      ..removeWhere((key, _) => key.toLowerCase() == 'npm_config_cache')
      ..['npm_config_cache'] = p.join(root.path, 'empty-cache');
    final result = await stage('rejected', environment: emptyCacheEnvironment);
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains('Offline locked npm dependency preparation failed'),
    );
    expect(result.stderr, contains('ENOTCACHED'));
    expect(Directory(p.join(root.path, 'rejected')).existsSync(), false);
    expect(await sourceIdentity(source), identity);
  });
  test('real npm packing preserves the exact staged inventory and refuses unowned bytes', () async {
    expect((await stage('stage')).exitCode, 0);
    Future<ProcessResult> pack(String output) =>
        Process.run(Platform.resolvedExecutable, [
          p.join(repository, 'tool/npm/pack.dart'),
          '--stage',
          p.join(root.path, 'stage'),
          '--output',
          p.join(root.path, output),
        ]);
    final result = await pack('packed');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final packed = jsonDecode(
      File(p.join(root.path, 'packed/npm-packed.json')).readAsStringSync(),
    ) as Map;
    expect(packed['source'], identity);
    expect(packed['version'], '1.2.3');
    expect(packed['registry_ready'], false);
    expect(
      File(p.join(root.path, 'packed', packed['filename'] as String))
          .lengthSync(),
      packed['compressed_bytes'],
    );
    final stageReceipt = File(p.join(root.path, 'stage/npm-stage.json'));
    final originalReceipt = stageReceipt.readAsStringSync();
    final altered = jsonDecode(originalReceipt) as Map;
    altered['descriptor_sha256'] = '0' * 64;
    stageReceipt.writeAsStringSync(jsonEncode(altered));
    final identityFailure = await pack('wrong-identity');
    expect(identityFailure.exitCode, 1);
    expect(identityFailure.stderr, contains('Npm stage identity differs'));
    expect(Directory(p.join(root.path, 'wrong-identity')).existsSync(), false);
    stageReceipt.writeAsStringSync(originalReceipt);
    File(p.join(root.path, 'stage/package/unowned.txt'))
        .writeAsStringSync('unexpected');
    final failed = await pack('rejected');
    expect(failed.exitCode, 1);
    expect(failed.stderr, contains('Unowned npm stage file'));
    expect(Directory(p.join(root.path, 'rejected')).existsSync(), false);
  }, timeout: const Timeout(Duration(minutes: 2)));
  test(
    'packer rejects altered npm-produced payload and removes its owned temporary output',
    () async {
      expect((await stage('stage')).exitCode, 0);
      final nodeResult = await Process.run('node', ['-p', 'process.execPath']);
      expect(nodeResult.exitCode, 0);
      final node = (nodeResult.stdout as String).trim();
      final npmCli = p.join(
        p.dirname(p.dirname(node)),
        'lib/node_modules/npm/bin/npm-cli.js',
      );
      expect(File(npmCli).existsSync(), isTrue);
      final tools = Directory(p.join(root.path, 'pack fixture tools'))
        ..createSync();
      final marker = File(p.join(root.path, 'actual npm completed'));
      final wrapper = File(p.join(tools.path, 'npm'))
        ..writeAsStringSync('''#!$node
const fs=require('node:fs'), zlib=require('node:zlib'), path=require('node:path');
const result=require('node:child_process').spawnSync(process.execPath,
 [${jsonEncode(npmCli)},...process.argv.slice(2)],{encoding:'utf8'});
if(result.status!==0){process.stderr.write(result.stderr);process.exit(result.status||1);}
const name=JSON.parse(result.stdout)[0].filename;
const file=path.join(process.argv[process.argv.indexOf('--pack-destination')+1],name);
const tar=zlib.gunzipSync(fs.readFileSync(file));
tar[512]^=1; // Ordinary first member bytes; header and gzip integrity remain valid.
fs.writeFileSync(file,zlib.gzipSync(tar));
fs.writeFileSync(${jsonEncode(marker.path)},'actual npm packed before alteration');
process.stdout.write(result.stdout);
''');
      expect(
        (await Process.run('/bin/chmod', ['755', wrapper.path])).exitCode,
        0,
      );
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          p.join(repository, 'tool/npm/pack.dart'),
          '--stage',
          p.join(root.path, 'stage'),
          '--output',
          p.join(root.path, 'altered-output'),
        ],
        environment: {
          ...Platform.environment,
          'PATH': '${tools.path}:${p.dirname(node)}:/usr/bin:/bin',
        },
      );
      expect(marker.readAsStringSync(), 'actual npm packed before alteration');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('TAR content differs from inventory'));
      expect(
        Directory(p.join(root.path, 'altered-output')).existsSync(),
        isFalse,
      );
      expect(
        root.listSync().where(
          (entry) => p.basename(entry.path).startsWith('.archway-npm-pack-'),
        ),
        isEmpty,
      );
    },
    skip: Platform.isWindows
        ? 'Packaging owner runs on POSIX; fixture executable uses a shebang.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
