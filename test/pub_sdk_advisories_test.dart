import 'dart:io';

import 'package:test/test.dart';

import '../tool/pub/sdk_advisories.dart';

void main() {
  // Original Dart 3.13.3 output captured 2026-10-14 from a real thin stage.
  // Only disposable absolute directory/archive paths were normalized.
  test('actual SDK dry-run and archive-export diagnostics admit only reviewed advisories', () {
    for (final export in [false, true]) {
      final text = File(
        'test/fixtures/pub-thin-sdk-${export ? 'export' : 'dry-run'}.txt',
      ).readAsStringSync();
      final code = export ? 0 : 65;
      expect(
        validatePubAdvisories(text, '', code, version: '0.2.0', export: export),
        {'exit_code': code, 'expected_advisories': 7},
      );
      for (final changed in [
        text.replaceFirst('archive: ^4.5.2', 'archive: ^4.5.3'),
        '$text\nUnexpected warning\n',
        text.replaceFirst('7 potential issues', '8 potential issues'),
        text.replaceFirst('1 package has newer', '2 packages have newer'),
      ]) {
        expect(
          () => validatePubAdvisories(
            changed,
            '',
            code,
            version: '0.2.0',
            export: export,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => validatePubAdvisories(
          text,
          'unexpected stderr',
          code,
          version: '0.2.0',
          export: export,
        ),
        throwsFormatException,
      );
      expect(
        () => validatePubAdvisories(
          text,
          '',
          export ? 65 : 0,
          version: '0.2.0',
          export: export,
        ),
        throwsFormatException,
      );
    }
  });
}
