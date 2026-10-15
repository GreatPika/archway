import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_native_input.dart';
import '../tool/release/generate_descriptor.dart';
import 'support/native_release_fixture.dart';

void main() {
  test('final input binds external descriptor bytes to independently verified native producer', () async {
    final fixture = await prepareNativeReleaseFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final built = await buildNativeFixture(fixture, 'native');
    expect(built.exitCode, 0, reason: '${built.stdout}\n${built.stderr}');
    final native = Directory(p.join(fixture.root.path, 'native'));
    final generated = Directory(p.join(fixture.root.path, 'descriptor'));
    final commit = fixture.identity['commit'] as String;
    await generateDescriptor(
      source: fixture.source,
      native: native,
      output: generated,
      expectedCommit: commit,
    );
    final descriptor = File(p.join(generated.path, 'acquisition.json'));
    final original = descriptor.readAsBytesSync();
    var invoked = false;
    Future<void> admit() => withNativeReleaseInput(
      source: fixture.source,
      native: native,
      descriptor: descriptor,
      expectedCommit: commit,
      inspect: (input) async {
        invoked = true;
      },
    );
    final changed = jsonDecode(utf8.decode(original)) as Map;
    changed['targets']['linux-x64']['url'] =
        'https://example.invalid/other.tar.gz';
    descriptor.writeAsStringSync(jsonEncode(changed));
    await expectLater(
      admit(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          'Acquisition descriptor differs from native producer',
        ),
      ),
    );
    expect(invoked, isFalse);
    descriptor.writeAsBytesSync(original);
    await withNativeReleaseInput(
      source: fixture.source,
      native: native,
      descriptor: descriptor,
      expectedCommit: commit,
      inspect: (input) async {
        invoked = true;
        expect(input.version, '1.2.3');
        expect(input.assets.keys.toSet(), {
          'archway-1.2.3-linux-x64.tar.gz',
          'archway-1.2.3-macos-arm64.tar.gz',
          'archway-1.2.3-windows-x64.zip',
          'acquisition.json',
        });
        expect(input.descriptorFile.readAsBytesSync(), original);
      },
    );
    expect(invoked, isTrue);
  });
}
