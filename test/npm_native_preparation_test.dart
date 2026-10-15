import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/npm/prepare_native.dart';

void main() {
  test('CI native preparation refuses altered pinned bytes before cache or process creation', () async {
    final root = Directory(
      Directory.systemTemp
          .createTempSync('npm-native-admit-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final wrapper = Directory(p.join(root.path, 'wrapper'))..createSync();
    final source = {'commit': 'a' * 40};
    final descriptor = File(p.join(wrapper.path, 'acquisition.json'))
      ..writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'version': '0.2.0',
          'source': source,
          'targets': {
            'linux-x64': {
              'size': 4,
              'sha256': sha256.convert(utf8.encode('good')).toString(),
              'manifest_sha256': 'b' * 64,
            },
          },
        }),
      );
    File(p.join(wrapper.path, 'package.json')).writeAsStringSync(
      '{"name":"archway-architecture-cli","version":"0.2.0","private":true}',
    );
    final archive = File(p.join(root.path, 'native.tar.gz'))
      ..writeAsStringSync('evil');
    final cache = Directory(p.join(root.path, 'cache'));
    final logs = Directory(p.join(root.path, 'logs'))..createSync();
    final recorder = InstalledCommandRecorder(output: logs);
    await expectLater(
      prepareNpmNative(
        wrapper: wrapper,
        cache: cache,
        target: 'linux-x64',
        receipt: {
          'version': '0.2.0',
          'source': source,
          'registry_ready': false,
          'descriptor_sha256': sha256
              .convert(descriptor.readAsBytesSync())
              .toString(),
        },
        archive: archive,
        node: File(Platform.resolvedExecutable),
        environment: {},
        recorder: recorder,
        workingDirectory: root,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('identity'),
        ),
      ),
    );
    expect(cache.existsSync(), isFalse);
    expect(logs.listSync(), isEmpty);
    expect(recorder.commands, isEmpty);
    expect(archive.readAsStringSync(), 'evil');
  });
}
