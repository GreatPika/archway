import 'package:test/test.dart';

import 'dart_flutter_process_smoke.dart' show validateFlutterTrace;

// Literal strace -xx fixtures, independent of the production-side encoder.
const executable = '/café/"\\archway';
const embedded = '/café/"\\dart';
const root = '/project';
const executableHex =
    r'"\x2f\x63\x61\x66\xc3\xa9\x2f\x22\x5c\x61\x72\x63\x68\x77\x61\x79"';
const embeddedHex = r'"\x2f\x63\x61\x66\xc3\xa9\x2f\x22\x5c\x64\x61\x72\x74"';
const rootFlagHex = r'"\x2d\x2d\x72\x6f\x6f\x74"';
const rootHex = r'"\x2f\x70\x72\x6f\x6a\x65\x63\x74"';
const checkHex = r'"\x63\x68\x65\x63\x6b"';
const analyticsHex =
    r'"\x2d\x2d\x73\x75\x70\x70\x72\x65\x73\x73\x2d\x61\x6e\x61\x6c\x79\x74\x69\x63\x73"';
const versionHex = r'"\x2d\x2d\x76\x65\x72\x73\x69\x6f\x6e"';
const first =
    '123 execve($executableHex, [$executableHex, $rootFlagHex, $rootHex, $checkHex], 0x123 /* 3 vars */) = 0';
const second =
    '124 execve($embeddedHex, [$embeddedHex, $analyticsHex, $versionHex], 0x456 /* 2 vars */) = 0';
const valid = '$first\n$second\n124 +++ exited with 0 +++\n';

void main() {
  void validate(String trace) => validateFlutterTrace(
    trace,
    executable: executable,
    embedded: embedded,
    root: root,
  );
  test(
    'hex trace accepts UTF-8, quotes and backslashes in executable paths',
    () {
      validate(valid);
    },
  );
  for (final entry in <String, String>{
    'wrong Archway executable': valid.replaceFirst(
      'execve($executableHex',
      'execve("wrong"',
    ),
    'wrong embedded executable': valid.replaceFirst(
      'execve($embeddedHex',
      'execve("wrong"',
    ),
    'wrong embedded argv zero': valid.replaceFirst('[$embeddedHex', '["wrong"'),
    'wrong version argument': valid.replaceFirst(versionHex, '"wrong"'),
    'additional argument': valid.replaceFirst(
      '$versionHex]',
      '$versionHex, "extra"]',
    ),
    'wrong project root': valid.replaceFirst(rootHex, '"wrong"'),
    'missing launch': '$first\n',
    'extra launch': '$valid$second\n',
    'network connection': '${valid}124 connect(3, {}, 16) = 0\n',
    'truncated executable': valid.replaceFirst(
      '$embeddedHex,',
      '$embeddedHex...,',
    ),
  }.entries) {
    test('hex trace rejects ${entry.key}', () {
      expect(() => validate(entry.value), throwsStateError);
    });
  }
}
