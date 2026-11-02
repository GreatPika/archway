import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/verify_native_assets.dart';

void main() {
  test('duplicate native asset cannot stand in for a missing supported target', () {
    final source = Directory.current;
    final fixture = Directory.systemTemp.createTempSync(
      'archway-asset-inventory-',
    );
    addTearDown(() => fixture.deleteSync(recursive: true));
    final inventory = jsonDecode(
      File(p.join(source.path, 'native/assets.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    final assets = inventory['assets'] as List;
    final files = [
      ...(inventory['source_sha256'] as Map).keys.cast<String>(),
      ...assets.map((asset) => asset['member'] as String),
    ];
    for (final relative in files) {
      final copy = File(p.join(fixture.path, relative));
      copy.parent.createSync(recursive: true);
      File(p.join(source.path, relative)).copySync(copy.path);
    }
    // The count is still three, and every entry names a supported target.
    // But repeating Linux does not establish that the macOS bridge was checked.
    assets[1] = Map<String, dynamic>.from(assets[0] as Map);
    File(p.join(fixture.path, 'native/assets.json'))
        .writeAsStringSync(jsonEncode(inventory));
    expect(
      () => verifyNativeAssets(fixture),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Incomplete supported native asset inventory',
        ),
      ),
    );
  });
}
