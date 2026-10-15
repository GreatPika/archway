// Private hosted SDK proof for the actual thin wrapper, not public availability.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/pub_snapshot_controls.dart';
import 'support/private_pub_host.dart';
import 'support/pub_stage_fixture.dart';

void main() {
  test('hosted thin wrapper uses its snapshot offline and preserves process IO', () async {
    final fixture = await preparePubStageFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final target = switch (Abi.current()) {
      Abi.linuxX64 => 'linux-x64',
      Abi.macosArm64 => 'macos-arm64',
      Abi.windowsX64 => 'windows-x64',
      _ => throw UnsupportedError('Unsupported hosted fixture host'),
    };
    final entry = File(p.join(fixture.root.path, 'process.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final input = await stdin.transform(utf8.decoder).join();
  stdout.write(jsonEncode({'args': args, 'input': input}));
  stderr.write('native fixture stderr');
  exitCode = 37;
}
''');
    final compiled = File(
      p.join(fixture.root.path, 'native${Platform.isWindows ? '.exe' : ''}'),
    );
    final build = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      entry.path,
      '-o',
      compiled.path,
    ]);
    expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
    final base = Directory(p.join(fixture.root.path, 'user cache'))
      ..createSync();
    final cache = Platform.isMacOS
        ? p.join(base.path, 'Library', 'Caches')
        : base.path;
    final descriptor = jsonDecode(
      fixture.descriptor.readAsStringSync(),
    ) as Map<String, dynamic>;
    final selected = (descriptor['targets'] as Map)[target] as Map;
    final installed = Directory(
      p.join(
        cache,
        'archway-pub',
        '0.2.0',
        target,
        selected['sha256'] as String,
      ),
    );
    final name = 'bin/$target/archway${Platform.isWindows ? '.exe' : ''}';
    final binary = File(p.join(installed.path, name));
    binary.parent.createSync(recursive: true);
    compiled.copySync(binary.path);
    if (!Platform.isWindows)
      expect(Process.runSync('chmod', ['755', binary.path]).exitCode, 0);
    final manifest = utf8.encode(
      jsonEncode({
        'version': '0.2.0',
        'target': target,
        'source': fixture.identity,
        'files': {
          name: {
            'size': compiled.lengthSync(),
            'mode': 493,
            'sha256': sha256.convert(compiled.readAsBytesSync()).toString(),
          },
        },
      }),
    );
    File(p.join(installed.path, 'manifest.json')).writeAsBytesSync(manifest);
    selected['manifest_sha256'] = sha256.convert(manifest).toString();
    fixture.descriptor.writeAsStringSync(jsonEncode(descriptor));
    final stage = Directory(p.join(fixture.root.path, 'stage'));
    final staged = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/pub/stage.dart',
      '--source',
      fixture.source.path,
      '--descriptor',
      fixture.descriptor.path,
      '--expected-commit',
      fixture.identity['commit'] as String,
      '--output',
      stage.path,
      '--registry-ready',
    ]);
    expect(staged.exitCode, 0, reason: '${staged.stdout}\n${staged.stderr}');
    final archive = File(p.join(fixture.root.path, 'upload.tar.gz'));
    final exported = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'publish',
      '--directory',
      p.join(stage.path, 'package'),
      '--to-archive',
      archive.path,
      '--skip-validation',
    ]);
    expect(
      exported.exitCode,
      0,
      reason: '${exported.stdout}\n${exported.stderr}',
    );
    // SDK validation is separately tested by export.dart; this owns activation.
    final host = await PrivatePubHost.start(
      archive,
      Directory(Platform.environment['PUB_CACHE']!),
      expectedVersion: descriptor['version'] as String,
    );
    addTearDown(host.close);
    final pubCache = Directory(p.join(fixture.root.path, 'pub cache'));
    final environment = {
      'PUB_CACHE': pubCache.path,
      'PUB_HOSTED_URL': host.url.toString(),
      'HOME': base.path,
      'XDG_CACHE_HOME': base.path,
      'LOCALAPPDATA': base.path,
      'DART_DATA_HOME': p.join(fixture.root.path, 'dart data'),
      'DASH__SUPPRESS_ANALYTICS': 'true',
    };
    final activation = await Process.run(Platform.resolvedExecutable, [
      '--suppress-analytics',
      'pub',
      'global',
      'activate',
      '--no-executables',
      'archway',
      '0.2.0',
    ], environment: environment);
    expect(
      activation.exitCode,
      0,
      reason: '${activation.stdout}\n${activation.stderr}',
    );
    expect(host.requests, contains('/archives/archway-0.2.0.tar.gz'));
    expect(Directory(p.join(pubCache.path, 'bin')).existsSync(), isFalse);
    final cwd = Directory(p.join(fixture.root.path, 'unrelated café'))
      ..createSync();
    const arguments = ['space value', 'café', '--literal=&;'];
    Future<({int exit, String out, String err})> run() async {
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--suppress-analytics',
          'pub',
          'global',
          'run',
          'archway:archway',
          ...arguments,
        ],
        environment: environment,
        workingDirectory: cwd.path,
      );
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.transform(utf8.decoder).join();
      process.stdin.write('inherited café\n');
      await process.stdin.close();
      return (exit: await process.exitCode, out: await out, err: await err);
    }

    void check(({int exit, String out, String err}) result) {
      expect(result.exit, 37, reason: '${result.out}\n${result.err}');
      expect(jsonDecode(result.out), {
        'args': arguments,
        'input': 'inherited café\n',
      });
      expect(result.err, 'native fixture stderr');
    }

    final activatedRequests = host.requests.length;
    check(await run());
    expect(host.requests.length, activatedRequests);
    await host.close();
    check(await run());
    final source = pubCache
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              p.basename(file.path) == 'archway.dart' &&
              p.basename(p.dirname(file.path)) == 'bin',
        )
        .single;
    final snapshots = await exercisePubSnapshots(
      pubCache: pubCache,
      wrapper: source.parent.parent,
      expectedExit: 37,
      invoke: () async {
        final result = await run();
        return (
          exitCode: result.exit,
          stdout: utf8.encode(result.out),
          stderr: utf8.encode(result.err),
        );
      },
    );
    expect((snapshots['cases'] as List).map((row) => (row as Map)['case']), [
      'poisoned-source-snapshot',
      'stale-snapshot',
      'missing-snapshot',
    ]);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
