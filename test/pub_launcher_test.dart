// Process fixtures prove wrapper dispatch, not Archway core or hosted acceptance.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File entry, executable;
  late Map<String, String> environment;
  setUpAll(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('pub process café-')
          .resolveSymbolicLinksSync(),
    );
    final target = switch (Abi.current()) {
      Abi.linuxX64 => 'linux-x64',
      Abi.macosArm64 => 'macos-arm64',
      Abi.windowsX64 => 'windows-x64',
      _ => throw UnsupportedError('Process fixture requires a supported host'),
    };
    final source = File(p.join(root.path, 'fixture.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.contains('--wait-for-signal')) {
    ProcessSignal.sigterm.watch().listen((_) {
      stderr.write('terminated');
      exit(42);
    });
    stdout.writeln('ready');
    return;
  }
  final input = await stdin.transform(utf8.decoder).join();
  stdout.write(jsonEncode({'args': args, 'input': input}));
  stderr.write('fixture stderr');
  exitCode = 37;
}
''');
    final compiled = File(
      p.join(root.path, 'fixture${Platform.isWindows ? '.exe' : ''}'),
    );
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      source.path,
      '-o',
      compiled.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    const archiveHash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final cache = Platform.isMacOS
        ? p.join(root.path, 'Library', 'Caches', 'archway-pub')
        : p.join(root.path, 'archway-pub');
    final installation = Directory(p.join(cache, '1.2.3', target, archiveHash));
    final name = 'bin/$target/archway${Platform.isWindows ? '.exe' : ''}';
    executable = File(p.join(installation.path, name));
    executable.parent.createSync(recursive: true);
    compiled.copySync(executable.path);
    if (!Platform.isWindows) {
      expect(Process.runSync('chmod', ['755', executable.path]).exitCode, 0);
    }
    final manifest = utf8.encode(
      jsonEncode({
        'version': '1.2.3',
        'target': target,
        'source': {'fixture': true},
        'files': {
          name: {
            'size': compiled.lengthSync(),
            'mode': 493,
            'sha256': sha256.convert(compiled.readAsBytesSync()).toString(),
          },
        },
      }),
    );
    File(p.join(installation.path, 'manifest.json')).writeAsBytesSync(manifest);
    final descriptor = {
      'schema_version': 1,
      'version': '1.2.3',
      'source': {'fixture': true},
      'targets': {
        for (final cell in ['linux-x64', 'macos-arm64', 'windows-x64'])
          cell: {
            'url': 'https://example.invalid/never-requested',
            'size': 1,
            'sha256': archiveHash,
            'manifest_sha256': sha256.convert(manifest).toString(),
          },
      },
    };
    entry = File(p.join(root.path, 'entry.dart'))
      ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
import '${File('tool/pub/launcher.dart').absolute.uri}';
Future<void> main(List<String> args) async {
  exitCode = await launchPubNative(jsonDecode(${jsonEncode(jsonEncode(descriptor))}) as Map<String, Object?>, args);
}
''');
    environment = {
      'HOME': root.path,
      'XDG_CACHE_HOME': root.path,
      'LOCALAPPDATA': root.path,
    };
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  Future<Process> start(List<String> args) => Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      entry.path,
      ...args,
    ],
    environment: environment,
    workingDirectory: root.path,
  );
  test(
    'warm launcher preserves literal argv, inherited streams and native exit',
    () async {
      final child = await start([
        'space value',
        'café',
        '--flag=literal',
        r'$HOME;echo nope',
      ]);
      child.stdin.write('input café\n');
      await child.stdin.close();
      final output = child.stdout.transform(utf8.decoder).join();
      final error = child.stderr.transform(utf8.decoder).join();
      expect(await child.exitCode, 37);
      expect(jsonDecode(await output), {
        'args': ['space value', 'café', '--flag=literal', r'$HOME;echo nope'],
        'input': 'input café\n',
      });
      expect(await error, 'fixture stderr');
    },
  );
  test(
    'prelaunch errors stay on stderr with exit 126 and no core stdout',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          entry.path,
        ],
        environment: {
          'HOME': 'relative',
          'XDG_CACHE_HOME': 'relative',
          'LOCALAPPDATA': 'relative',
        },
      );
      expect(result.exitCode, 126);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Missing absolute user cache location'));
    },
  );
  if (!Platform.isWindows) {
    test('POSIX launcher forwards SIGTERM to its waiting child', () async {
      final child = await start(['--wait-for-signal']);
      final error = child.stderr.transform(utf8.decoder).join();
      final lines = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      expect(await lines.first.timeout(const Duration(seconds: 15)), 'ready');
      expect(child.kill(ProcessSignal.sigterm), isTrue);
      expect(await child.exitCode.timeout(const Duration(seconds: 15)), 42);
      expect(await error, 'terminated');
    });
  }
}
