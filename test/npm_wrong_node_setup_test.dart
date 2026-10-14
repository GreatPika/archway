import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/setup_npm_wrong_node.dart';

void main() {
  test(
    'wrong Node refuses changed official bytes before extraction or identity',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('wrong-node-admission-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final archive = File(p.join(root.path, 'changed.tar.gz'))
        ..writeAsStringSync('not the reviewed official archive');
      final output = Directory(p.join(root.path, 'prepared'));
      final target = switch (Abi.current()) {
        Abi.linuxX64 => 'linux-x64',
        Abi.macosArm64 => 'macos-arm64',
        Abi.windowsX64 => 'windows-x64',
        _ => throw UnsupportedError('Unsupported fixture host'),
      };
      await expectLater(
        prepareNpmWrongNode(target: target, output: output, archive: archive),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            'Wrong-Node archive checksum mismatch',
          ),
        ),
      );
      expect(output.listSync(), isEmpty);
      expect(archive.readAsStringSync(), 'not the reviewed official archive');
    },
  );
}
