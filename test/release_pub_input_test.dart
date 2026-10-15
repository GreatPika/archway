import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/pub_stage_transport.dart';
import '../tool/ci/release_pub_input.dart';
import '../tool/pub/stage.dart';
import 'support/pub_stage_fixture.dart';

void main() {
  test('final pub input rejects coherently repacked wrapper bytes outside canonical source', () async {
    final fixture = await preparePubStageFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final stage = Directory(p.join(fixture.root.path, 'stage'));
    final commit = fixture.identity['commit'] as String;
    await stagePub(
      source: fixture.source,
      descriptor: fixture.descriptor,
      output: stage,
      expectedCommit: commit,
    );
    var invoked = false;
    Future<void> admit(Directory transport, Map<String, Object?> record) =>
        withPubReleaseInput(
          source: fixture.source,
          identity: fixture.identity,
          descriptor: fixture.descriptor,
          transport: transport,
          expectedTransportJson: jsonEncode(record),
          runId: '123',
          runAttempt: '2',
          registryReady: false,
          inspect: (input) async {
            invoked = true;
          },
        );
    final clean = Directory(p.join(fixture.root.path, 'clean'));
    final cleanRecord = await writePubTransport(
      stage,
      fixture.source,
      clean,
      commit,
      '123',
      '2',
    );
    final file = File(p.join(stage.path, 'package/tool/pub/launcher.dart'));
    file.writeAsStringSync(
      '${file.readAsStringSync()}\n// coherent unrelated bytes\n',
    );
    final metadata = File(p.join(stage.path, 'pub-stage.json'));
    final changed = jsonDecode(metadata.readAsStringSync()) as Map;
    changed['files']['tool/pub/launcher.dart']['size'] = file.lengthSync();
    changed['files']['tool/pub/launcher.dart']['sha256'] = sha256
        .convert(file.readAsBytesSync())
        .toString();
    metadata.writeAsStringSync('${jsonEncode(changed)}\n');
    final altered = Directory(p.join(fixture.root.path, 'altered'));
    final alteredRecord = await writePubTransport(
      stage,
      fixture.source,
      altered,
      commit,
      '123',
      '2',
    );
    await expectLater(
      admit(altered, alteredRecord),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'reason',
          'Pub transported stage differs from canonical wrapper',
        ),
      ),
    );
    expect(invoked, isFalse);
    await admit(clean, cleanRecord);
    expect(invoked, isTrue);
  });
}
