import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/loopback_tls.dart';

import 'support/npm_stage_fixture.dart';
import '../tool/npm/installed_route.dart';
import '../tool/ci/installed_command_recorder.dart';
import '../tool/ci/native_acceptance_capture.dart';
import 'support/npm_native_fixture.dart';

void main() {
  late String node;
  late Directory compilation;
  late File executable;
  setUpAll(() async {
    final resolved = await Process.run(
      Platform.environment['ARCHWAY_TEST_NODE'] ?? 'node',
      ['-p', 'process.execPath'],
    );
    expect(resolved.exitCode, 0, reason: '${resolved.stderr}');
    node = File((resolved.stdout as String).trim()).resolveSymbolicLinksSync();
    compilation = Directory(
      Directory.systemTemp
          .createTempSync('npm payload ')
          .resolveSymbolicLinksSync(),
    );
    executable = File(
      p.join(compilation.path, Platform.isWindows ? 'payload.exe' : 'payload'),
    );
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/support/npm_launcher_payload.dart',
      '-o',
      executable.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() => compilation.deleteSync(recursive: true));
  test('identical packed local global and cache routes preserve native transport cold and offline', () async {
    final fixture = await prepareNpmStageFixture();
    final root = fixture.root;
    HttpServer? server;
    try {
      final target = Platform.isWindows
          ? 'windows-x64'
          : Platform.isMacOS
          ? 'macos-arm64'
          : 'linux-x64';
      final native = await npmNativeFixture(
        root,
        Platform.isWindows ? 'zip' : 'tar.gz',
        payload: executable.readAsBytesSync(),
        executableMode: 0x1ed,
        sourceIdentity: fixture.identity,
        nativeTarget: target,
      );
      final descriptor =
          jsonDecode(fixture.descriptor.readAsStringSync()) as Map;
      descriptor['targets'][target] = {
        ...native.pin,
        'url': descriptor['targets'][target]['url'],
      };
      fixture.descriptor.writeAsStringSync(jsonEncode(descriptor));
      Future<void> dart(List<String> args) async {
        final result = await Process.run(Platform.resolvedExecutable, args);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }

      await dart([
        'tool/npm/stage.dart',
        '--source',
        fixture.source.path,
        '--descriptor',
        fixture.descriptor.path,
        '--output',
        p.join(root.path, 'stage'),
        '--expected-commit',
        fixture.identity['commit']! as String,
      ]);
      await dart([
        'tool/npm/pack.dart',
        '--stage',
        p.join(root.path, 'stage'),
        '--output',
        p.join(root.path, 'packed'),
      ]);
      final packed = jsonDecode(
        File(p.join(root.path, 'packed', 'npm-packed.json')).readAsStringSync(),
      ) as Map;
      final archive = p.join(root.path, 'packed', packed['filename'] as String);
      final npmCli = Platform.isWindows
          ? p.join(p.dirname(node), 'node_modules', 'npm', 'bin', 'npm-cli.js')
          : p.join(
              p.dirname(p.dirname(node)),
              'lib',
              'node_modules',
              'npm',
              'bin',
              'npm-cli.js',
            );
      expect(File(npmCli).existsSync(), true);
      final tls = await createLoopbackTls(root);
      final context = tls.context;
      for (final route in ['local', 'global', 'cache']) {
        final base = Directory(p.join(root.path, '$route route café'))
          ..createSync();
        final project = Directory(p.join(base.path, 'project'))..createSync();
        File(p.join(project.path, 'package.json'))
            .writeAsStringSync('{"private":true}');
        final home = Directory(p.join(base.path, 'user home ü'))..createSync();
        final foreign = Directory(p.join(base.path, 'other cwd'))..createSync();
        final cache = p.join(base.path, 'npm cache');
        final runtimeBin = Directory(p.join(base.path, 'runtime bin'))
          ..createSync();
        if (!Platform.isWindows) {
          Link(p.join(runtimeBin.path, 'sh')).createSync('/bin/sh');
        }
        final observed = File(p.join(base.path, 'origins.jsonl'));
        server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.contentLength = native.archive.lengthSync();
          await request.response.addStream(native.archive.openRead());
          await request.response.close();
        });
        // Fixture-only transport and invocation observation, no runtime URL option.
        final preload = File(p.join(base.path, 'transport.cjs'))
          ..writeAsStringSync('''
const fs=require('node:fs'),https=require('node:https');const get=https.get;
if(process.argv[1]){const main=fs.realpathSync(process.argv[1]);if(main.endsWith('archway.cjs')){fs.appendFileSync(${jsonEncode(observed.path)},JSON.stringify(main)+'\\n');if(process.env.ARCHWAY_FIXTURE_UNSUPPORTED)Object.defineProperty(process,'platform',{value:'aix'});}}
https.get=function(url,...args){if(url.href!==${jsonEncode(descriptor['targets'][target]['url'])})throw Error('unexpected URL');return get.call(this,new URL('https://127.0.0.1:${server.port}/archive'),...args);};
''');
        final environment = Map<String, String>.from(Platform.environment)
          ..removeWhere(
            (key, _) =>
                key.toLowerCase().startsWith('npm_config_') ||
                [
                  'node_options',
                  'node_path',
                  'node_auth_token',
                  'npm_token',
                ].contains(key.toLowerCase()),
          );
        environment.addAll({
          'HOME': home.path,
          'USERPROFILE': home.path,
          'LOCALAPPDATA': p.join(home.path, 'AppData', 'Local'),
          'XDG_CACHE_HOME': p.join(home.path, '.cache'),
          'NODE_EXTRA_CA_CERTS': tls.certificate.path,
          'NODE_OPTIONS': '--require ${jsonEncode(preload.path)}',
          'PATH': [
            p.dirname(node),
            runtimeBin.path,
          ].join(Platform.isWindows ? ';' : ':'),
          'npm_config_cache': cache,
          'npm_config_offline': 'true',
          'npm_config_ignore_scripts': 'true',
          'npm_config_audit': 'false',
          'npm_config_fund': 'false',
          'npm_config_registry': 'http://127.0.0.1:9',
        });
        for (final name in ['userconfig', 'globalconfig']) {
          final file = File(p.join(base.path, '$name.npmrc'))
            ..writeAsStringSync('');
          environment['npm_config_$name'] = file.path;
        }
        final installation = route == 'local'
            ? project
            : Directory(p.join(base.path, 'global prefix'));
        final installedRoute = NpmInstalledRoute(
          route: route,
          archive: File(archive),
          node: File(node),
          npmCli: File(npmCli),
          project: project,
          installation: installation,
          environment: environment,
          recorder: InstalledCommandRecorder(
            output: Directory(p.join(base.path, 'install receipts'))
              ..createSync(),
          ),
        );
        await installedRoute.install();
        Future<void> launch({
          String? failure,
          Map<String, String> extra = const {},
          Directory? cwd,
        }) async {
          final invocation = installedRoute.invocation([
            'space argument',
            'café',
          ]);
          late int code;
          late String output;
          late String errors;
          if (Platform.isWindows) {
            final input = File(p.join(base.path, 'launch.stdin'))
              ..writeAsStringSync('inherited input\n');
            final outFile = File(p.join(base.path, 'launch.stdout'));
            final errFile = File(p.join(base.path, 'launch.stderr'));
            final out = outFile.openSync(mode: FileMode.write);
            RandomAccessFile? err;
            try {
              err = errFile.openSync(mode: FileMode.write);
              code = await captureAcceptanceProcess(
                invocation,
                (cwd ?? foreign).path,
                {...environment, ...extra},
                out,
                err,
                const Duration(seconds: 30),
                windowsStdinFile: input,
                windowsCommand: installedRoute.windowsCommandFor(invocation),
                waitForWindowsJobEmpty: true,
              );
            } finally {
              try {
                out.closeSync();
              } finally {
                err?.closeSync();
              }
            }
            output = outFile.readAsStringSync();
            errors = errFile.readAsStringSync();
          } else {
            final child = await Process.start(
              invocation.first,
              invocation.skip(1).toList(),
              workingDirectory: (cwd ?? foreign).path,
              environment: {...environment, ...extra},
              includeParentEnvironment: false,
            );
            child.stdin.write('inherited input\n');
            await child.stdin.close();
            final out = child.stdout.transform(utf8.decoder).join();
            final err = child.stderr.transform(utf8.decoder).join();
            code = await child.exitCode;
            output = await out;
            errors = await err;
          }
          expect(code, failure == null ? 37 : 126, reason: errors);
          if (failure != null) {
            expect(output, isEmpty);
            expect(errors, startsWith('archway launcher:'));
            expect(errors, contains(failure));
            return;
          }
          expect(jsonDecode(output), {
            'args': ['space argument', 'café'],
            'stdin': 'inherited input\n',
          });
          expect(errors, 'native stderr\n');
        }

        await launch();
        expect(requests, 1, reason: route);
        final origin = jsonDecode(observed.readAsLinesSync().single) as String;
        final packageRoot = p.dirname(p.dirname(origin));
        expect(installedRoute.packageRoot.path, packageRoot);
        expect(
          File(p.join(packageRoot, 'acquisition.json')).readAsBytesSync(),
          fixture.descriptor.readAsBytesSync(),
        );
        if (route == 'cache') {
          expect(p.isWithin(cache, origin), true);
          expect(origin, contains('_npx'));
          expect(
            Directory(p.join(project.path, 'node_modules')).existsSync(),
            false,
          );
        } else {
          expect(p.isWithin(installedRoute.installation.path, origin), true);
          installedRoute.relocate(Directory(p.join(base.path, 'relocated ü')));
        }
        await server.close(force: true);
        server = null;
        final otherCwd = Directory(p.join(base.path, 'second cwd ü'))
          ..createSync();
        await launch(cwd: otherCwd);
        expect(foreign.listSync(), isEmpty);
        expect(otherCwd.listSync(), isEmpty);
        expect(requests, 1, reason: route);
        expect(observed.readAsLinesSync(), hasLength(2));
        await launch(
          failure: 'unsupported target aix',
          extra: {'ARCHWAY_FIXTURE_UNSUPPORTED': '1'},
        );
        final nativeCache = Directory(
          p.joinAll([
            home.path,
            if (Platform.isWindows) ...[
              'AppData',
              'Local',
            ] else if (Platform.isMacOS) ...[
              'Library',
              'Caches',
            ] else
              '.cache',
            'archway',
            'npm',
          ]),
        );
        final record = File(
          p.join(
            nativeCache.path,
            descriptor['version'] as String,
            target,
            native.pin['sha256'] as String,
          ),
        );
        final originalRecord = record.readAsBytesSync();
        record.writeAsStringSync('foreign record');
        try {
          await launch(failure: 'Invalid native cache publication record');
          expect(record.readAsStringSync(), 'foreign record');
        } finally {
          record.writeAsBytesSync(originalRecord);
        }
        final savedCache = nativeCache.renameSync(
          '${nativeCache.path}.fixture-saved',
        );
        try {
          await launch(failure: 'ECONNREFUSED');
          expect(record.existsSync(), false);
          expect(
            nativeCache.listSync(recursive: true).whereType<File>(),
            isEmpty,
          );
        } finally {
          nativeCache.deleteSync(recursive: true);
          savedCache.renameSync(nativeCache.path);
        }
        await launch();
        expect(requests, 1, reason: route);
      }
    } finally {
      await server?.close(force: true);
      root.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
