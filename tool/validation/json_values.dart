/// Structural equality of decoded JSON, independent of object-key order.
bool sameJson(Object? left, Object? right) {
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!sameJson(left[i], right[i])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && sameJson(left[key], right[key]),
        );
  }
  return left == right;
}

/// Contract ordering is by Unicode scalar value, not UTF-16 code unit.
int compareUnicode(String left, String right) {
  final a = left.runes.iterator, b = right.runes.iterator;
  while (a.moveNext()) {
    if (!b.moveNext()) return 1;
    final compared = a.current.compareTo(b.current);
    if (compared != 0) return compared;
  }
  return b.moveNext() ? -1 : 0;
}
