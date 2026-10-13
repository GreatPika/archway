import 'dart:async';

import 'package:test/test.dart';

import 'support/windows_installer_lifecycle_fake.dart';
import 'support/windows_installer_registry.dart';

void main() {
  test(
    'completion waits for both ownership and uninstaller disappearance',
    () async {
      final fake = FakeWindowsInstallation();
      final lifecycle = fake.open();
      fake.installed();
      fake.onSleep = fake.removed;
      await lifecycle.run(() async {
        await lifecycle.uninstall();
      });
      expect(fake.calls.single, [
        '${FakeWindowsInstallation.root}\\unins000.exe',
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/SP-',
      ]);
      expect(fake.now, const Duration(milliseconds: 50));
    },
  );
  test(
    'uninstall requires exactly one executable and verified same-root owner',
    () async {
      for (final mode in ['missing', 'empty', 'foreign', 'no-exe', 'two-exe']) {
        final fake = FakeWindowsInstallation();
        final lifecycle = fake.open();
        fake.installed();
        if (mode == 'missing') fake.owner = null;
        if (mode == 'empty') fake.owner = WindowsInstallerOwner();
        if (mode == 'foreign') {
          fake.owner = WindowsInstallerOwner(
            root: WindowsRegistryValue.string(r'C:\foreign'),
          );
        }
        if (mode == 'no-exe') fake.executables.clear();
        if (mode == 'two-exe')
          fake.executables.add('${FakeWindowsInstallation.root}\\unins001.exe');
        fake.onCommand = () async {
          fake.removed();
          return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
        };
        await expectLater(
          lifecycle.uninstall(),
          throwsStateError,
          reason: mode,
        );
        expect(fake.calls, isEmpty, reason: mode);
      }
    },
  );

  test('one deadline includes command and rejects success at expiry', () async {
    final fake = FakeWindowsInstallation();
    final lifecycle = fake.open();
    fake.installed();
    fake.onCommand = () async {
      fake.now = const Duration(seconds: 180);
      fake.removed();
      return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
    };
    await expectLater(lifecycle.uninstall(), throwsA(isA<TimeoutException>()));
    expect(fake.budgets, [const Duration(seconds: 180)]);
    expect(fake.now, const Duration(seconds: 180));
  });

  test(
    'unexpected nonzero exit cannot become marker-only completion',
    () async {
      final fake = FakeWindowsInstallation();
      final lifecycle = fake.open();
      fake.installed();
      fake.onCommand = () async {
        fake.removed();
        return (exitCode: 7, stdout: <int>[], stderr: <int>[]);
      };
      await expectLater(lifecycle.uninstall(), throwsStateError);
      expect(fake.now, Duration.zero);
    },
  );

  test(
    'registered install receives one cleanup attempt after unrelated failure',
    () async {
      final fake = FakeWindowsInstallation();
      final lifecycle = fake.open();
      final primary = StateError('later assertion');
      fake.onCommand = () async {
        fake.calls.length == 1 ? fake.installed() : fake.removed();
        return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
      };
      await expectLater(
        lifecycle.run(() async {
          await lifecycle.install(r'C:\old.exe');
          throw primary;
        }),
        throwsA(same(primary)),
      );
      expect(fake.calls, hasLength(2));
      expect(fake.owner, isNull);
    },
  );

  test(
    'intentional refusal restores cleanup only with reverified same-root owner',
    () async {
      for (final owner in ['same', 'missing', 'foreign', 'success']) {
        final fake = FakeWindowsInstallation();
        final lifecycle = fake.open();
        fake.onCommand = () async {
          if (fake.calls.length == 1) {
            fake.installed();
          } else if (fake.calls.length == 2) {
            if (owner == 'missing') fake.owner = null;
            if (owner == 'foreign')
              fake.owner = WindowsInstallerOwner(
                root: WindowsRegistryValue.string(r'C:\foreign'),
              );
            return (
              exitCode: owner == 'success' ? 0 : 1,
              stdout: <int>[],
              stderr: <int>[],
            );
          } else {
            fake.removed();
          }
          return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
        };
        final primary = StateError('later assertion');
        Future<void> exerciseRefusal() => lifecycle.run(() async {
          await lifecycle.install(r'C:\old.exe');
          if (owner == 'same') {
            await lifecycle.uninstall(expectSuccess: false);
            throw primary;
          }
          await expectLater(
            lifecycle.uninstall(expectSuccess: false),
            throwsStateError,
            reason: owner,
          );
        });
        if (owner == 'same') {
          await expectLater(exerciseRefusal(), throwsA(same(primary)));
        } else {
          await exerciseRefusal();
        }
        expect(fake.calls, hasLength(owner == 'same' ? 3 : 2), reason: owner);
      }
    },
  );

  test(
    'locked upgrade accepts only exact refusal and retains cleanup ownership',
    () async {
      for (final code in [20, 1, 0]) {
        final fake = FakeWindowsInstallation();
        final lifecycle = fake.open();
        fake.onCommand = () async {
          if (fake.calls.length == 1) fake.installed();
          if (fake.calls.length == 3) fake.removed();
          return (
            exitCode: fake.calls.length == 2 ? code : 0,
            stdout: <int>[],
            stderr: <int>[],
          );
        };
        await expectLater(
          lifecycle.run(() async {
            await lifecycle.install(r'C:\old.exe');
            await lifecycle.install(
              r'C:\upgrade.exe',
              expectSuccess: false,
              expectedExit: 20,
            );
            throw StateError('later assertion');
          }),
          throwsStateError,
        );
        expect(fake.calls, hasLength(code == 20 ? 3 : 2));
      }
    },
  );

  test('uncertain uninstall never relaunches during failure cleanup', () async {
    for (final error in [
      TimeoutException('job still live'),
      StateError('spawn unknown'),
    ]) {
      final fake = FakeWindowsInstallation();
      final lifecycle = fake.open();
      fake.onCommand = () async {
        if (fake.calls.length == 1) {
          fake.installed();
          return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
        }
        throw error;
      };
      await expectLater(
        lifecycle.run(() async {
          await lifecycle.install(r'C:\old.exe');
          await lifecycle.uninstall(expectSuccess: false);
        }),
        throwsA(same(error)),
      );
      expect(fake.calls, hasLength(2));
      expect(fake.reports, isEmpty);
    }
  });

  test(
    'polling uses the command remainder and checks final marker-read time',
    () async {
      for (final mode in ['owner', 'exe', 'final-read']) {
        final fake = FakeWindowsInstallation();
        final lifecycle = fake.open();
        fake.installed();
        fake.onCommand = () async {
          fake.now = const Duration(milliseconds: 179975);
          if (mode != 'owner') fake.owner = null;
          if (mode != 'exe') fake.executables.clear();
          if (mode == 'final-read')
            fake.onReadOwner = () {
              fake.now = const Duration(seconds: 180);
            };
          return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
        };
        await expectLater(
          lifecycle.uninstall(),
          throwsA(isA<TimeoutException>()),
        );
        expect(fake.now, const Duration(seconds: 180));
        expect(fake.calls, hasLength(1));
      }
    },
  );
}
