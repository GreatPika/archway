import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'bootstrap refuses wrong official SDK bytes before extraction or executable dispatch',
    () async {
      final root = Directory.systemTemp.createTempSync('bootstrap café-');
      addTearDown(() => root.deleteSync(recursive: true));
      final bin = Directory(p.join(root.path, 'bin'))..createSync();
      final curl = File(p.join(bin.path, 'curl'))
        ..writeAsStringSync(
          '#!/usr/bin/env bash\nprintf "wrong SDK bytes" > "\${@: -1}"\n',
        );
      expect(Process.runSync('chmod', ['+x', curl.path]).exitCode, 0);
      final output = Directory(p.join(root.path, 'sdk'));
      final result = await Process.run(
        'bash',
        ['tool/ci/bootstrap_pub_dart.sh', 'linux-x64', output.path],
        environment: {
          ...Platform.environment,
          'PATH':
              '${bin.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH']}',
          'GITHUB_ENV': p.join(root.path, 'environment'),
          'GITHUB_PATH': p.join(root.path, 'paths'),
        },
      ).timeout(const Duration(seconds: 20));
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('Official bootstrap SDK checksum differs'),
      );
      expect(Directory(p.join(output.path, 'dart-sdk')).existsSync(), isFalse);
      expect(File(p.join(root.path, 'environment')).existsSync(), isFalse);
    },
    skip: Platform.isWindows
        ? 'POSIX shell admission control; native Windows bootstrap is a CI gate'
        : false,
  );
}
