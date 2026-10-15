// Shared fail-closed decoding for installed-route admission.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'release_execution_receipts.dart';

Map<String, dynamic> receiptObject(Object? value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('Expected receipt object');
  return value;
}

List<dynamic> receiptList(Object? value) {
  if (value is! List) throw const FormatException('Expected receipt list');
  return value;
}

/// Receipt result integers are not interchangeable with booleans or doubles.
bool exactReceipt(Object? actual, Object? expected) {
  if (expected is Map) {
    return actual is Map &&
        actual.length == expected.length &&
        expected.keys.every(
          (key) =>
              actual.containsKey(key) &&
              exactReceipt(actual[key], expected[key]),
        );
  }
  if (expected is List) {
    return actual is List &&
        actual.length == expected.length &&
        List.generate(
          expected.length,
          (i) => i,
        ).every((i) => exactReceipt(actual[i], expected[i]));
  }
  if (expected is int && actual is! int ||
      expected is double && actual is! double)
    return false;
  return actual == expected;
}

void requireReceipt(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

File oneReceiptFile(Directory directory, String name) {
  final matches = directory
      .listSync(recursive: true, followLinks: false)
      .where((entry) => p.basename(entry.path) == name)
      .toList();
  if (matches.length != 1)
    throw FormatException('Expected one original evidence file: $name');
  final file = File(matches.single.path);
  readOrdinaryBytes(file);
  return file;
}
