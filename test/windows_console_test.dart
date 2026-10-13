import 'dart:io';

import 'package:test/test.dart';

import 'support/windows_console.dart';
import 'windows_console_capability.dart' as capability;

void main() {
  test(
    'LifecycleSupportTest.test_windows_launch_enables_ctrl_c_before_spawn',
    () {
      final calls = <String>[];
      final result = enableWindowsCtrlCBeforeSpawn(() {
        calls.add('spawn');
        return 23;
      }, setIgnored: (ignored) => calls.add('ignore=$ignored'));
      expect(calls, ['ignore=false', 'spawn']);
      expect(result, 23);
      calls.clear();
      expect(
        () => enableWindowsCtrlCBeforeSpawn(
          () => calls.add('spawn'),
          setIgnored: (_) => throw StateError('normalization failed'),
        ),
        throwsStateError,
      );
      expect(calls, isEmpty);
    },
  );
  test(
    'console cleanup preserves native failure and attempts every release',
    () {
      for (final operation in [
        'AttachConsole',
        'SetConsoleCtrlHandler',
        'GenerateConsoleCtrlEvent',
      ]) {
        final primary = OSError(operation, 5);
        final calls = <int>[];
        expect(() {
          var failed = false;
          try {
            throw primary;
          } catch (_) {
            failed = true;
            rethrow;
          } finally {
            finishWindowsConsoleCleanup([
              () {
                calls.add(1);
                throw StateError('release one');
              },
              () {
                calls.add(2);
                throw StateError('release two');
              },
              () {
                calls.add(3);
              },
            ], operationFailed: failed);
          }
        }, throwsA(same(primary)));
        expect(calls, [1, 2, 3]);
      }
    },
  );

  test('console cleanup surfaces first release failure without losing later releases', () {
    final first = OSError('FreeConsole', 6);
    final calls = <int>[];
    expect(
      () => finishWindowsConsoleCleanup([
        () {
          calls.add(1);
          throw first;
        },
        () {
          calls.add(2);
          throw OSError('CloseHandle', 6);
        },
        () {
          calls.add(3);
        },
      ], operationFailed: false),
      throwsA(same(first)),
    );
    expect(calls, [1, 2, 3]);
    calls.clear();
    finishWindowsConsoleCleanup([
      () {
        calls.add(1);
      },
      () {
        calls.add(2);
      },
    ], operationFailed: false);
    expect(calls, [1, 2]);
  });
  test('console readiness publishes a closed complete frame', () {
    final root = Directory.systemTemp.createTempSync('console-ready-');
    try {
      final marker = File('${root.path}/ready');
      const frame = '[123,456]';
      capability.publishReady(marker, frame);
      expect(marker.readAsStringSync(), frame);
      expect(File('${marker.path}.pending').existsSync(), isFalse);
      final failed = File('${root.path}/failed');
      Directory('${failed.path}.pending').createSync();
      expect(
        () => capability.publishReady(failed, frame),
        throwsA(isA<FileSystemException>()),
      );
      expect(failed.existsSync(), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
