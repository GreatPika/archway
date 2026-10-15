import 'dart:io';
import 'dart:ffi';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/setup_pub_dart.dart';
import 'support/pub_stage_fixture.dart';

void main() {
  test('SDK preparation retains the reviewed official release inputs', () {
    expect(
      pubSdkBase,
      'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/',
    );
    expect(pubSdkPins, {
      'linux-x64':
          '549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7',
      'macos-arm64':
          'c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc',
      'windows-x64':
          '30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e',
    });
  });
  test(
    'SDK preparation refuses wrong host and unpinned archive before extraction',
    () async {
      final fixture = await preparePubStageFixture();
      final root = fixture.root;
      addTearDown(() => root.deleteSync(recursive: true));
      final target = switch (Abi.current()) {
        Abi.linuxX64 => 'linux-x64',
        Abi.macosArm64 => 'macos-arm64',
        Abi.windowsX64 => 'windows-x64',
        _ => throw UnsupportedError('Unsupported test host'),
      };
      final archive = File(p.join(root.path, 'sdk.zip'))
        ..writeAsStringSync('not the reviewed SDK');
      final output = Directory(p.join(root.path, 'prepared'));
      final commit = fixture.identity['commit'] as String;
      Future<ProcessResult> run(String cell) =>
          Process.run(Platform.resolvedExecutable, [
            'run',
            'tool/ci/setup_pub_dart.dart',
            '--target',
            cell,
            '--source',
            fixture.source.path,
            '--expected-commit',
            commit,
            '--output',
            output.path,
            '--sdk-archive',
            archive.path,
          ]);
      final wrong = await run(
        target == 'windows-x64' ? 'linux-x64' : 'windows-x64',
      );
      expect(wrong.exitCode, 1);
      expect(
        wrong.stderr,
        contains('SDK preparation target differs from actual host'),
      );
      expect(output.existsSync(), isFalse);
      final mismatch = await run(target);
      expect(mismatch.exitCode, 1);
      expect(
        mismatch.stderr,
        contains('Official SDK archive checksum differs'),
      );
      expect(output.existsSync(), isFalse);
      expect(archive.readAsStringSync(), 'not the reviewed SDK');
    },
  );
}
