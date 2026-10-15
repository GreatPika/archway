import 'dart:convert';

import 'package:test/test.dart';

import '../tool/ci/release_installed_process_receipts.dart';
import '../tool/ci/release_pub_sdk_receipts.dart';

void main() {
  test('SDK preparation binds official archive and activation to original commands', () {
    const pin =
        '549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7';
    const dart = '/sdk café/dart-sdk/bin/dart';
    const version = 'Dart SDK version: 3.13.3 (stable) on "linux_x64"';
    final source = <String, Object?>{'commit': 'a' * 40};
    final proof = <String, dynamic>{
      'schema_version': 1,
      'target': 'linux-x64',
      'source': source,
      'dart': dart,
      'version': version,
      'cache_prepared': true,
      'prepared_cache': '/sdk café/pub-cache',
      'archive': {
        'url': 'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/dartsdk-linux-x64-release.zip',
        'size': 238710402,
        'sha256': pin,
      },
    };
    InstalledProcessEvidence capture(List<String> argv, [String text = '']) => (
      arguments: argv,
      exitCode: 0,
      stdout: utf8.encode(text),
      stderr: <int>[],
    );
    final commands = [
      capture([
        '/usr/bin/unzip',
        '-q',
        '/sdk café/dartsdk-linux-x64-release.zip',
        '-d',
        '/sdk café',
      ]),
      capture([dart, '--version'], '$version\n'),
      capture([
        dart,
        '--suppress-analytics',
        'pub',
        'get',
        '--enforce-lockfile',
      ], 'Got dependencies!\n'),
    ];
    void admit({
      String executable = dart,
      String checksum = '$pin  dartsdk-linux-x64-release.zip',
      List<InstalledProcessEvidence>? rows,
    }) => validatePubSdkProcesses(
      proof,
      rows ?? commands,
      source: source,
      target: 'linux-x64',
      dart: executable,
      checksum: checksum,
    );
    admit();
    expect(() => admit(executable: '/other/dart'), throwsFormatException);
    expect(
      () => admit(checksum: '${'b' * 64}  dartsdk-linux-x64-release.zip'),
      throwsFormatException,
    );
    expect(
      () => admit(
        rows: [...commands]
          ..[1] = capture([dart, '--version'], 'Dart SDK version: 3.13.5\n'),
      ),
      throwsFormatException,
    );
    expect(
      () => admit(rows: [...commands]..[2] = capture([dart, 'pub', 'get'])),
      throwsFormatException,
    );
    expect(
      () => admit(
        rows: [...commands]
          ..[0] = capture([
            '/usr/bin/unzip',
            '-q',
            '/other.zip',
            '-d',
            '/sdk café',
          ]),
      ),
      throwsFormatException,
    );
    proof['archive']['size'] = 238710402.0;
    expect(admit, throwsFormatException);
  });
}
