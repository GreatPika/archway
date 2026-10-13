import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../contracts/run_tests.dart';

void main() {
  test(
    'runner preserves successful and failing test exits without changing seeds',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'archway-contract-status-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/helper/fixtures').createSync(recursive: true);
      final seed = File('${root.path}/helper/fixtures/seed.json')
        ..writeAsStringSync('{}');
      File('${root.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'files': {
            'helper/fixtures/seed.json': sha256
                .convert(seed.readAsBytesSync())
                .toString(),
          },
        }),
      );
      for (final status in [0, 2]) {
        var executions = 0;
        expect(
          await runContractChecks(
            root,
            executeTests: () async {
              executions++;
              return status;
            },
          ),
          status == 0 ? 0 : 1,
        );
        expect(executions, 1);
        expect(seed.readAsStringSync(), '{}');
      }
    },
  );
  test(
    'runner rejects bad inventory before dispatching its explicit suite',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'archway-contract-dispatch-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/helper/fixtures').createSync(recursive: true);
      File('${root.path}/manifest.json').writeAsStringSync('{"files":{}}');
      File('${root.path}/unlisted.json').writeAsStringSync('{}');
      var dispatched = false;
      expect(
        await runContractChecks(
          root,
          executeTests: () async {
            dispatched = true;
            return 0;
          },
        ),
        1,
      );
      expect(dispatched, isFalse);
    },
  );
  test(
    'runner rejects helper seed changes even when tests report success',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'archway-contract-fixtures-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/helper/fixtures').createSync(recursive: true);
      final seed = File('${root.path}/helper/fixtures/seed.json')
        ..writeAsStringSync('{}');
      File('${root.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'files': {
            'helper/fixtures/seed.json': sha256
                .convert(seed.readAsBytesSync())
                .toString(),
          },
        }),
      );
      expect(
        await runContractChecks(
          root,
          executeTests: () async {
            seed.writeAsStringSync('[]');
            return 0;
          },
        ),
        1,
      );
    },
  );
  test('manifest rejects modified, missing and unlisted contract bytes', () {
    final root = Directory.systemTemp.createTempSync(
      'archway-contract-manifest-',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/contract.json')
      ..writeAsStringSync('{}\n');
    File('${root.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'files': {
          'contract.json': sha256.convert(source.readAsBytesSync()).toString(),
        },
      }),
    );
    expect(verifyManifest(root), isEmpty);
    source.writeAsStringSync('[]\n');
    expect(verifyManifest(root), ['hash mismatch: contract.json']);
    source.deleteSync();
    expect(verifyManifest(root), ['missing file: contract.json']);
    source.writeAsStringSync('{}\n');
    File('${root.path}/unlisted.json').writeAsStringSync('{}\n');
    expect(verifyManifest(root), ['unlisted file: unlisted.json']);
  });
}
