import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/native_payload.dart';
import 'support/native_release_fixture.dart';

void main() {
  test(
    'nested source inventory paths retain canonical native spelling',
    () async {
      final fixture = await prepareNativeReleaseFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final versions = await nativeVersions(
        fixture.source,
        '3.13.3',
        '24.21.0',
      );
      expect(versions['typescript'], '5.9.3');
      final assets = await sourceNativeAssets(fixture.source);
      expect(assets, contains('assets/typescript/helper.cjs'));
      expect(assets, contains('contracts/json/policy.schema.json'));
    },
  );

  test(
    'native inventory path construction preserves parent alias refusal',
    () async {
      final fixture = await prepareNativeReleaseFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final schemas = Directory(
        p.join(fixture.source.path, 'contracts', 'json'),
      );
      final moved = schemas.renameSync(p.join(fixture.root.path, 'schemas'));
      Link(schemas.path).createSync(moved.path);
      await expectLater(
        sourceNativeAssets(fixture.source),
        throwsFormatException,
      );
      expect(moved.listSync(), hasLength(3));
    },
  );
}
