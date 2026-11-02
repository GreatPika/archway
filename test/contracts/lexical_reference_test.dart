import 'package:test/test.dart' hide matches;

import '../../contracts/compatibility/lexical_reference.dart';

void main() {
  group('LexicalReference', () {
    test('test_matching', () {
      expect(matches('src/', 'src/a.ts'), isTrue);
      expect(matches('src/', 'src2/a.ts'), isFalse);
      expect(matches('src', 'src/a.ts'), isFalse);
      expect(matches('./', 'src/a.ts'), isTrue);
      expect(matches('src/Foo.ts', 'src/foo.ts'), isFalse);
    });
    test('test_idempotent', () {
      for (final value in [
        '.',
        'a/..',
        r'src\a.ts',
        './a//b/../c/',
        'src/e\u0301.ts',
      ]) {
        expect(normalize(normalize(value)), normalize(value), reason: value);
      }
    });
    test('test_invalid', () {
      for (final value in [
        '',
        '../repo/a.ts',
        'a/../../b',
        '/src/a',
        r'C:\a',
        'C:a',
        r'\\server\share\x',
        r'\\?\C:\x',
        'src/CON.ts',
        'src/lpt1',
        'src/a.ts:secret',
        'a/evil.',
        'a/b ',
        'a/\x00b',
        'a/\x7fb',
        'a/*.ts',
        'https://a/b',
        'src/[a].ts',
        'src/{a}.ts',
      ]) {
        expect(() => normalize(value), throwsFormatException, reason: value);
      }
    });
    test('test_normalization', () {
      const examples = {
        r'src\a.ts': 'src/a.ts',
        './src//x/../a.ts': 'src/a.ts',
        'a/..': './',
        '.': './',
        './': './',
        'src/': 'src/',
        'src': 'src',
        'src/%2e%2e/a.ts': 'src/%2e%2e/a.ts',
        'src/e\u0301.ts': 'src/é.ts',
        'a/../b': 'b',
        'a\\b\\': 'a/b/',
      };
      for (final entry in examples.entries) {
        expect(normalize(entry.key), entry.value, reason: entry.key);
      }
    });
  });
}
