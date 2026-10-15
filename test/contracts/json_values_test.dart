import 'package:test/test.dart';

import '../../tool/validation/json_values.dart';

void main() {
  test('decoded JSON equality ignores object order but preserves arrays', () {
    expect(
      sameJson(
        {
          'a': [1, null],
          'b': true,
        },
        {
          'b': true,
          'a': [1, null],
        },
      ),
      isTrue,
    );
    expect(sameJson([1, 2], [2, 1]), isFalse);
    expect(sameJson({'a': null}, {'b': null}), isFalse);
    expect(sameJson([1], [1, 1]), isFalse);
  });
  test(
    'contract ordering compares Unicode scalars rather than UTF-16 units',
    () {
      expect(compareUnicode('\uE000', '\u{10000}'), lessThan(0));
      expect(compareUnicode('a', 'aa'), lessThan(0));
      expect(compareUnicode('aa', 'a'), greaterThan(0));
      expect(compareUnicode('é', 'é'), 0);
    },
  );
}
