import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/npm/pack.dart';
import '../tool/npm/packed_candidate.dart';
import '../tool/npm/stage.dart' show stageNpm;
import 'support/npm_stage_fixture.dart';

void main() {
  test('packed final admission binds actual archive to regenerated canonical stage', () async {
    final fixture = await prepareNpmStageFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final stage = Directory(p.join(fixture.root.path, 'stage'));
    final packed = Directory(p.join(fixture.root.path, 'packed'));
    final commit = fixture.identity['commit'] as String;
    await stageNpm(fixture.source, fixture.descriptor, stage, commit);
    await packNpm(stage, packed);
    final regenerated = Directory(p.join(fixture.root.path, 'regenerated'));
    await stageNpm(fixture.source, fixture.descriptor, regenerated, commit);
    Future<Map<String, Object?>> admit() => verifyNpmPackedCandidate(
      regenerated,
      packed,
      expectedCommit: commit,
      registryReady: false,
    );
    final admitted = await admit();
    expect(admitted['source'], fixture.identity);
    expect(admitted['version'], '1.2.3');
    final receiptFile = File(p.join(packed.path, 'npm-packed.json'));
    final receipt = jsonDecode(receiptFile.readAsStringSync()) as Map;
    receipt['stage_inventory_sha256'] = '0' * 64;
    receiptFile.writeAsStringSync(jsonEncode(receipt));
    await expectLater(
      admit(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'canonical stage boundary',
          'Packed npm candidate differs from canonical stage',
        ),
      ),
    );
    final readyStage = Directory(p.join(fixture.root.path, 'ready-stage'));
    final readyPacked = Directory(p.join(fixture.root.path, 'ready-packed'));
    await stageNpm(
      fixture.source,
      fixture.descriptor,
      readyStage,
      commit,
      registryReady: true,
    );
    await packNpm(readyStage, readyPacked);
    final readyReceipt = jsonDecode(
      File(p.join(readyPacked.path, 'npm-packed.json')).readAsStringSync(),
    ) as Map;
    // Two genuine pack outputs: retain the private archive and its byte pin,
    // but claim the ready stage's metadata. The final member check must refuse.
    receiptFile.writeAsStringSync(
      jsonEncode({
        ...readyReceipt,
        'sha256': admitted['sha256'],
        'compressed_bytes': admitted['compressed_bytes'],
      }),
    );
    await expectLater(
      verifyNpmPackedCandidate(
        readyStage,
        packed,
        expectedCommit: commit,
        registryReady: true,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'actual packed member boundary',
          'Unexpected TAR member metadata',
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
