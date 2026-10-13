import 'dart:convert';

import 'package:test/test.dart';

import '../../contracts/helper/validate_contract.dart';

void main() {
  group('helper transport', () {
    final scenarios = <(String, int, int, int, num, int, bool, bool)>[
      ('at-caps', 8 * 1048576, 64 * 1048576, 256 * 1024, 120, 0, true, true),
      ('request-over', 8 * 1048576 + 1, 1, 0, 1, 0, true, false),
      ('stdout-over', 1, 64 * 1048576 + 1, 0, 1, 0, true, false),
      ('stderr-over', 1, 1, 256 * 1024 + 1, 1, 0, true, false),
      ('timeout', 1, 1, 0, 120.001, 0, true, false),
      ('exit', 1, 1, 0, 1, 1, true, false),
      ('no-eof', 1, 1, 0, 1, 0, false, false),
    ];
    for (final (name, request, stdout, stderr, elapsed, exit, eof, valid)
        in scenarios) {
      test(name, () {
        expect(
          () => validateTransport(
            requestBytes: request,
            stdoutBytes: stdout,
            stderrBytes: stderr,
            elapsedSeconds: elapsed,
            exitCode: exit,
            eof: eof,
          ),
          valid ? returnsNormally : throwsFormatException,
        );
      });
    }
  });
  group('helper framing', () {
    final scenarios = <(String, List<int>, bool)>[
      ('valid', utf8.encode(' {} \n'), true),
      ('duplicate', utf8.encode('{"a":1,"a":2}'), false),
      ('partial', utf8.encode('{"a":'), false),
      ('two-values', utf8.encode('{} {}'), false),
      ('invalid-utf8', [123, 34, 97, 34, 58, 34, 255, 34, 125], false),
      ('bom', [239, 187, 191, 123, 125], false),
      ('nan', utf8.encode('{"a":NaN}'), false),
    ];
    for (final (name, raw, valid) in scenarios) {
      test(
        name,
        () => expect(
          () => decodeEnvelope(raw),
          valid ? returnsNormally : throwsFormatException,
        ),
      );
    }
  });
  group('Dart framing regressions', () {
    for (final (name, raw) in [
      ('nested duplicate', r'{"list":[{"a":1,"a":2}]}'),
      ('escaped duplicate', r'{"a":1,"\u0061":2}'),
      ('nested escaped duplicate', r'{"list":[{"a":1,"\u0061":2}]}'),
    ]) {
      test(
        name,
        () => expect(
          () => decodeEnvelope(utf8.encode(raw)),
          throwsFormatException,
        ),
      );
    }
    test('same key in different objects and structural text in strings', () {
      const raw = r'{"a":{"x":1},"b":[{"x":2}],"text":"{\"x\":3}"}';
      expect(decodeEnvelope(utf8.encode(raw)), jsonDecode(raw));
    });
    test('escaped lone surrogate survives framing for semantic rejection', () {
      final decoded =
          decodeEnvelope(utf8.encode(r'{"target":"\ud800"}')) as Map;
      expect((decoded['target'] as String).codeUnits, [0xd800]);
    });
    test('raw UTF-8 surrogate encoding is rejected', () {
      expect(
        () => decodeEnvelope([34, 0xed, 0xa0, 0x80, 34]),
        throwsFormatException,
      );
    });
  });
}
