import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:test/test.dart';

import '../tool/ci/native_fixture_pins.dart';
import 'prepare_package_process_pub.dart';
import '../tool/ci/prepare_native_acceptance.dart';

void main() {
  test(
    'official Flutter metadata requires a unique exact reviewed release',
    () {
      for (final target in fixtureFlutterPins.keys) {
        final pin = fixtureFlutterPins[target]!;
        final record = <String, Object>{
          'version': '3.47.4',
          'channel': 'stable',
          'dart_sdk_version': '3.13.3',
          'dart_sdk_arch': target.split('-')[1],
          'archive': pin.archive,
          'sha256': pin.sha256,
        };
        expect(
          flutterRecord({
            'releases': [record],
          }, target),
          record,
        );
        expect(
          () => flutterRecord({
            'releases': [record, record],
          }, target),
          throwsFormatException,
        );
        for (final key in record.keys) {
          expect(
            () => flutterRecord({
              'releases': [
                {...record, key: 'unexpected'},
              ],
            }, target),
            throwsFormatException,
          );
        }
      }
    },
  );
  test(
    'environment creates fresh private home, cache, Git config and hooks',
    () {
      final root = Directory.systemTemp.createTempSync('prepare-env-');
      addTearDown(() => root.deleteSync(recursive: true));
      final dart = p.join(
        root.path,
        'flutter',
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dart',
      );
      final env = preparationEnvironment(
        root,
        dart,
        p.join(root.path, 'flutter'),
        git: p.join(root.path, 'git', 'bin', 'git'),
        inherited: {
          'HOME': '/personal',
          'PUB_CACHE': '/personal',
          'GIT_CONFIG_COUNT': '99',
          'NODE_OPTIONS': '--require=personal',
          'HTTPS_PROXY': 'http://proxy',
          'SystemRoot': r'C:\Windows',
        },
      );
      expect(env['HOME'], p.join(root.path, 'home'));
      expect(env['PUB_CACHE'], p.join(root.path, 'pub-cache'));
      expect(env['GIT_CONFIG_COUNT'], '1');
      expect(env['GIT_CONFIG_KEY_0'], 'core.hooksPath');
      expect(env, isNot(contains('NODE_OPTIONS')));
      expect(env['HTTPS_PROXY'], 'http://proxy');
      expect(
        env['PATH']!.split(Platform.isWindows ? ';' : ':').first,
        p.dirname(dart),
      );
      expect(File(env['GIT_CONFIG_GLOBAL']!).readAsStringSync(), '');
      expect(Directory(env['GIT_CONFIG_VALUE_0']!).listSync(), isEmpty);
      expect(
        () => preparationEnvironment(root, dart, '', git: 'git'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'downloads retry only transient HTTP failures and never bad bytes',
    () async {
      final root = Directory.systemTemp.createTempSync('prepare-download-');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final status in [
        502,
        503,
        504,
        400,
        401,
        403,
        404,
        408,
        429,
        500,
        501,
      ]) {
        var requests = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          requests++;
          request.response.statusCode = requests == 1 ? status : 200;
          request.response.write('wrong');
          await request.response.close();
        });
        final delays = <Duration>[];
        final file = File(p.join(root.path, '$status'));
        await expectLater(
          downloadFixture(
            Uri.parse('http://127.0.0.1:${server.port}/archive'),
            file,
            expected: '0' * 64,
            delay: (duration) async {
              expect(file.existsSync(), isFalse);
              delays.add(duration);
            },
          ),
          throwsA(anyOf(isA<HttpException>(), isA<FormatException>())),
        );
        final transient = [502, 503, 504].contains(status);
        expect(requests, transient ? 2 : 1);
        expect(delays, transient ? [const Duration(seconds: 1)] : isEmpty);
        await server.close(force: true);
        await subscription.cancel();
      }
    },
  );

  test(
    'readiness binds real specs, locks and pinned generator configs',
    () async {
      final root = Directory.systemTemp.createTempSync('prepare-ready-');
      addTearDown(() => root.deleteSync(recursive: true));
      await expectLater(
        fixtureReadiness(root),
        throwsA(isA<FileSystemException>()),
      );
      for (final name in [
        'pub/hosted',
        'pub/path',
        'pub/workspace',
        'git-fixture',
        'flutter-fixture',
      ]) {
        for (final file in [
          'pubspec.yaml',
          'pubspec.lock',
          '.dart_tool/package_config.json',
        ]) {
          final output = File(p.join(root.path, name, file));
          output.parent.createSync(recursive: true);
          output.writeAsStringSync(
            file.endsWith('.json')
                ? jsonEncode({'configVersion': 2, 'generatorVersion': '3.13.3'})
                : 'prepared',
          );
        }
      }
      final evidence = await fixtureReadiness(root);
      expect(evidence.length, 5);
      expect(
        evidence['pub/hosted']!['pubspec.lock'],
        'b0f4b2e7996a5f4f315bdbc6233973376144870ecd6524e417c05c36dde88745',
      );
      final config = File(
        p.join(root.path, 'flutter-fixture/.dart_tool/package_config.json'),
      );
      config.writeAsStringSync(
        '{"configVersion":2,"generatorVersion":"wrong"}',
      );
      await expectLater(fixtureReadiness(root), throwsFormatException);
      config.deleteSync();
      await expectLater(
        fixtureReadiness(root),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'prepares genuine offline hosted, path and workspace projects',
    () async {
      final cache = Platform.environment['PUB_CACHE'];
      if (cache == null || cache.isEmpty) {
        fail(
          'Preparation prerequisite: PUB_CACHE must identify a prepared cache.',
        );
      }
      final collection = Directory(
        p.join(cache, 'hosted', 'pub.dev', 'collection-1.19.1'),
      );
      if (!collection.existsSync()) {
        fail(
          'Preparation prerequisite: collection 1.19.1 is missing from PUB_CACHE.',
        );
      }
      final sourceHash = File(
        p.join(cache, 'hosted-hashes', 'pub.dev', 'collection-1.19.1.sha256'),
      );
      if (!sourceHash.existsSync()) {
        fail(
          'Preparation prerequisite: collection 1.19.1 cache checksum is missing.',
        );
      }
      final root = Directory.systemTemp.createTempSync('prepare-real-pub-');
      addTearDown(() => root.deleteSync(recursive: true));
      final env = preparationEnvironment(
        root,
        Platform.resolvedExecutable,
        '',
        git: preparationGit(),
      );
      for (final entity in collection.listSync(recursive: true)) {
        final destination = p.join(
          env['PUB_CACHE']!,
          'hosted',
          'pub.dev',
          'collection-1.19.1',
          p.relative(entity.path, from: collection.path),
        );
        if (entity is Directory)
          Directory(destination).createSync(recursive: true);
        if (entity is File) {
          File(destination).parent.createSync(recursive: true);
          entity.copySync(destination);
        }
      }
      final hashes = File(
        p.join(
          env['PUB_CACHE']!,
          'hosted-hashes',
          'pub.dev',
          'collection-1.19.1.sha256',
        ),
      );
      hashes.parent.createSync(recursive: true);
      sourceHash.copySync(hashes.path);
      final base = Directory(p.join(root.path, 'pub'));
      await preparePubFixtures(base, Platform.resolvedExecutable, env);
      for (final name in ['hosted', 'path', 'workspace']) {
        final path = p.join(base.path, name);
        expect(File(p.join(path, 'pubspec.lock')).existsSync(), isTrue);
        final config = jsonDecode(
          File(p.join(path, '.dart_tool/package_config.json'))
              .readAsStringSync(),
        );
        expect(config['generatorVersion'], '3.13.3');
        final names = (config['packages'] as List).map((e) => e['name']);
        expect(
          names,
          containsAll(switch (name) {
            'hosted' => ['fixture', 'collection'],
            'path' => ['fixture', 'outside_pkg'],
            _ => ['workspace_root', 'app', 'core'],
          }),
        );
      }
    },
  );

  test(
    'manifest preserves pinned provenance, readiness and excludes proxies',
    () async {
      final root = Directory.systemTemp.createTempSync('prepare-manifest-');
      addTearDown(() => root.deleteSync(recursive: true));
      final source = {'commit': 'a' * 40, 'tree': 'b' * 40};
      final manifest = nativeFixtureManifest(
        root: root,
        target: 'linux-x64',
        source: source,
        environment: {
          'HOME': root.path,
          'HTTPS_PROXY': 'secret',
          'http_proxy': 'secret',
          'no_proxy': 'secret',
        },
        flutter: {'archive': fixtureFlutterPins['linux-x64']!.archive},
        gitPubspecSha: 'c' * 64,
        readiness: {
          'fixture': {'pubspec.lock': 'd' * 64},
        },
      );
      expect(manifest['source'], source);
      expect(manifest['schema_version'], 1);
      expect(manifest['environment'], {'HOME': root.path});
      final pins = manifest['pins'] as Map;
      expect(pins['wrong_node'], {
        'version': '24.19.0',
        'url':
            'https://nodejs.org/dist/v24.19.0/node-v24.19.0-linux-x64.tar.gz',
        'sha256':
            'f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4',
      });
      expect(
        (pins['git'] as Map)['ref'],
        '4d80610a878cdb3f9f10e6a16a2af6631251a3c6',
      );
      expect((pins['git'] as Map)['package_pubspec_sha256'], 'c' * 64);
      expect(manifest['readiness'], {
        'fixture': {'pubspec.lock': 'd' * 64},
      });
      expect(
        manifest['dart_sdk'],
        p.join(root.path, 'flutter', 'bin', 'cache', 'dart-sdk'),
      );
    },
  );

  test(
    'manifest uses native Windows components for every serialized fixture path',
    () {
      final windows = p.Context(style: p.Style.windows);
      final manifest = nativeFixtureManifest(
        root: Directory(windows.join(r'C:\fixture root', 'prepared')),
        target: 'windows-x64',
        source: {},
        environment: {},
        flutter: {},
        gitPubspecSha: 'a' * 64,
        readiness: {},
        paths: windows,
      );
      expect(
        {
          for (final key in [
            'dart_sdk',
            'wrong_node',
            'pub_fixture',
            'git_fixture',
            'flutter_sdk',
            'flutter_fixture',
          ])
            key: manifest[key],
        },
        {
          'dart_sdk': r'C:\fixture root\prepared\flutter\bin\cache\dart-sdk',
          'wrong_node':
              r'C:\fixture root\prepared\node-v24.19.0-win-x64\node.exe',
          'pub_fixture': r'C:\fixture root\prepared\pub',
          'git_fixture': r'C:\fixture root\prepared\git-fixture',
          'flutter_sdk': r'C:\fixture root\prepared\flutter',
          'flutter_fixture': r'C:\fixture root\prepared\flutter-fixture',
        },
      );
    },
  );

  test('preparation rejects foreign host before allocating output', () async {
    final root = Directory.systemTemp.createTempSync('prepare-host-');
    addTearDown(() => root.deleteSync(recursive: true));
    final output = Directory(p.join(root.path, 'output'));
    await expectLater(
      prepareNativeFixtures(
        target: 'unsupported',
        output: output,
        repository: Directory.current,
      ),
      throwsArgumentError,
    );
    expect(output.existsSync(), isFalse);
  });
  test('archive extraction chooses only native tools for reviewed formats', () {
    expect(
      officialExtractionCommand(
        '/tmp/flutter.zip',
        '/tmp/root',
        'macos-arm64',
        {},
      ),
      ['/usr/bin/unzip', '-q', '/tmp/flutter.zip', '-d', '/tmp/root'],
    );
    expect(
      officialExtractionCommand(
        '/tmp/flutter.tar.xz',
        '/tmp/root',
        'linux-x64',
        {},
      ),
      ['/usr/bin/tar', '-xf', '/tmp/flutter.tar.xz', '-C', '/tmp/root'],
    );
    expect(
      officialExtractionCommand('flutter.zip', 'root', 'windows-x64', {
        'SystemRoot': r'C:\Windows',
      }).first,
      r'C:\Windows\System32\tar.exe',
    );
    expect(
      () => officialExtractionCommand('unknown.rar', 'root', 'linux-x64', {}),
      throwsArgumentError,
    );
  });
  test(
    'Git discovery skips a nonexecutable earlier PATH entry',
    () async {
      final root = Directory.systemTemp.createTempSync('prepare-git-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final blocked = File(p.join(root.path, 'blocked', 'git'));
      final executable = File(p.join(root.path, 'executable', 'git'));
      for (final file in [blocked, executable]) {
        file.parent.createSync();
        file.writeAsStringSync('#!/bin/sh\nprintf "selected-fixture\\n"\n');
      }
      posix.chmod(blocked.path, '0600'); // 0600: readable, not executable.
      posix.chmod(executable.path, '0700'); // 0700: owner executable.
      await expectLater(
        Process.run(blocked.path, []),
        throwsA(isA<ProcessException>()),
      );
      expect(
        (await Process.run(executable.path, [])).stdout,
        'selected-fixture\n',
      );
      final child = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${p.absolute('.dart_tool/package_config.json')}',
          p.absolute('test/support/preparation_git_child.dart'),
        ],
        environment: {
          ...Platform.environment,
          'PATH': [blocked.parent.path, executable.parent.path].join(':'),
        },
        includeParentEnvironment: false,
      );
      expect(child.exitCode, 0, reason: '${child.stderr}');
      expect(
        (child.stdout as String).trim(),
        executable.resolveSymbolicLinksSync(),
      );
    },
    skip: Platform.isWindows ? 'POSIX executable permission regression' : false,
  );
}
