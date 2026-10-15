import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'windows_job_capability.dart' show verifyReadinessFailure;

void main() {
  test('missing malformed marker is a failed control, not the expected parse error', () async {
    final root = Directory.systemTemp.createTempSync('archway-missing-ready-');
    try {
      // Mutation: suppress the fixture writer's malformed readiness file.
      await expectLater(
        verifyReadinessFailure(
          'malformed-readiness',
          File('${root.path}/ready.json'),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });
  test('malformed readiness requires an actual parse error', () async {
    final root = Directory.systemTemp.createTempSync('archway-invalid-ready-');
    final ready = File('${root.path}/ready.json');
    try {
      ready.writeAsStringSync('invalid json');
      await verifyReadinessFailure('malformed-readiness', ready);
      ready.writeAsStringSync('{}');
      await expectLater(
        verifyReadinessFailure('malformed-readiness', ready),
        throwsStateError,
      );
      await expectLater(
        verifyReadinessFailure('before-readiness', ready),
        throwsStateError,
      );
      ready.deleteSync();
      await verifyReadinessFailure('before-readiness', ready);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
