import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_pub_receipts.dart';
import '../tool/validation/json_schema.dart';
import 'pub_receipt_fixtures.dart';

void main() {
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    test(
      '$target admits public original output and rejects coherent corruptions',
      () {
        final root = Directory.systemTemp.createTempSync('pub-receipt-');
        addTearDown(() => root.deleteSync(recursive: true));
        final original = pubReceiptFixture(root, target);
        void validate(Map<String, dynamic> proof) =>
            validatePubReceipt(proof, root, target, Directory.current);
        validate(original);
        for (final change in [
          'missing',
          'failed',
          'wrong-code',
          'malformed',
          'schema-incomplete',
          'wrong-original-code',
        ]) {
          final proof =
              jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
          final log = File(
            p.join(root.path, 'analysis/missing-node.stdout.log'),
          );
          final saved = log.readAsBytesSync();
          try {
            switch (change) {
              case 'missing':
                (proof['analysis']['cases'] as List).removeLast();
              case 'failed':
                proof['analysis']['cases'][0]['exit'] = 2;
              case 'wrong-code':
                proof['analysis']['cases'][6]['error'] = 'WRONG_CODE';
              case 'wrong-original-code':
                final value = jsonDecode(utf8.decode(saved)) as Map;
                value['payload']['tool_errors'][0]['code'] =
                    'TYPESCRIPT_ASSETS_UNAVAILABLE';
                value['diagnostics'][0]['code'] =
                    'TYPESCRIPT_ASSETS_UNAVAILABLE';
                expect(
                  ContractSchema(
                    jsonDecode(
                      File('contracts/json/public-result.schema.json')
                          .readAsStringSync(),
                    ),
                  ).errors(value),
                  isEmpty,
                );
                final bytes = utf8.encode(jsonEncode(value));
                log.writeAsBytesSync(bytes);
                proof['analysis']['cases'][6]['stdout_sha256'] = sha256
                    .convert(bytes)
                    .toString();
              case 'malformed':
              case 'schema-incomplete':
                final bytes = utf8.encode(
                  change == 'malformed'
                      ? 'not json'
                      : '{"command":"check","exit_code":2}',
                );
                log.writeAsBytesSync(bytes);
                proof['analysis']['cases'][6]['stdout_sha256'] = sha256
                    .convert(bytes)
                    .toString();
            }
            expect(
              () => validate(proof),
              throwsFormatException,
              reason: change,
            );
          } finally {
            log.writeAsBytesSync(saved);
          }
        }
      },
    );
  }
}
