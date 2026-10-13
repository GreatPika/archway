import 'dart:io';

import 'support/windows_installer_lifecycle.dart';

import 'package:test/test.dart';

import 'support/windows_installer_lifecycle_fake.dart';
import 'support/windows_installer_registry.dart';

void main() {
  test('Windows lexical stale-path and host gates precede registry access', () {
    for (final path in [
      r'C:\old..txt',
      r'\old..txt',
      r'\\host\old..txt',
      'C:old..txt',
      '../old..txt',
      'dir/../old..txt',
      'dir/.. /old..txt',
      'dir./old..txt',
      'dir/old.txt',
      'obsolete..dir/probe.txt',
      'old..txt',
      'dir/old..txt/',
      'dir//old..txt',
      'dir/old..txt:stream',
    ]) {
      final fake = FakeWindowsInstallation();
      expect(
        () => fake.open(staleFile: path),
        throwsArgumentError,
        reason: path,
      );
      expect(fake.registryOpens, 0);
    }
    for (final root in [r'C:\.', r'C:\foo\..', r'\\host\share\.']) {
      final fake = FakeWindowsInstallation();
      var opened = false;
      expect(
        () => WindowsInstallerLifecycle(
          root: root,
          staleFile: 'obsolete/installer-probe..txt',
          disposableAccount: true,
          nativeWindowsX64: true,
          command: fake.command,
          rootExists: () => false,
          registryFactory: () {
            opened = true;
            return fake;
          },
        ),
        throwsArgumentError,
        reason: root,
      );
      expect(opened, isFalse, reason: root);
    }
    final fake = FakeWindowsInstallation();
    expect(() => fake.open(nativeWindowsX64: false), throwsUnsupportedError);
    expect(() => fake.open(disposableAccount: false), throwsArgumentError);
    expect(fake.registryOpens, 0);
    fake.rootExists = true;
    expect(fake.open, throwsStateError);
    expect(fake.registryOpens, 0);
    fake.rootExists = false;
    fake.owner = WindowsInstallerOwner();
    expect(fake.open, throwsStateError);
  });
  test(
    'raw or absent original Path is restored without decoding after failure',
    () async {
      for (final original in [
        null,
        WindowsRegistryValue.raw(7, [255, 0, 1]),
      ]) {
        final fake = FakeWindowsInstallation()..path = original;
        final lifecycle = fake.open();
        final primary = StateError('unrelated assertion');
        await expectLater(
          lifecycle.run(() async {
            fake.writePath(WindowsRegistryValue.string('synthetic', type: 2));
            throw primary;
          }),
          throwsA(same(primary)),
        );
        expect(fake.path, original);
      }
    },
  );

  test('primary stack survives cleanup and restoration errors without original Path', () async {
    const secret = 'original Path must never enter diagnostics';
    final fake = FakeWindowsInstallation()
      ..path = WindowsRegistryValue.string(secret);
    final original = fake.path;
    final lifecycle = fake.open();
    final primary = StateError('synthetic Path mismatch');
    final primaryStack = StackTrace.fromString('original assertion stack');
    fake.onCommand = () async {
      if (fake.calls.length > 1) throw StateError(secret);
      fake.installed();
      return (exitCode: 0, stdout: <int>[], stderr: <int>[]);
    };
    fake.onWritePath = (value) {
      if (value == original) throw StateError(secret);
    };
    Object? observed;
    StackTrace? observedStack;
    try {
      await lifecycle.run(() async {
        await lifecycle.install(r'C:\old.exe');
        Error.throwWithStackTrace(primary, primaryStack);
      });
    } catch (error, stack) {
      observed = error;
      observedStack = stack;
    }
    expect(observed, same(primary));
    expect(observedStack.toString(), primaryStack.toString());
    expect(fake.calls, hasLength(2));
    expect(fake.reports, [
      'Owned installer cleanup failed (StateError)',
      'Test Path restoration failed (StateError)',
    ]);
    expect(fake.reports.join(), isNot(contains(secret)));
  });

  test(
    'restoration failure is visible and sanitized after successful body',
    () async {
      final fake = FakeWindowsInstallation();
      final lifecycle = fake.open();
      fake.onWritePath = (_) {
        throw StateError('private original contents');
      };
      await expectLater(
        lifecycle.run(() async => 42),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Test Path restoration failed (StateError)',
          ),
        ),
      );
    },
  );
  test(
    'root lookup access failure cannot become absence before registry access',
    () {
      final fake = FakeWindowsInstallation();
      final denied = FileSystemException('denied', '', const OSError('', 5));
      var opened = false;
      IOOverrides.runZoned(
        () {
          expect(
            () => WindowsInstallerLifecycle(
              root: FakeWindowsInstallation.root,
              staleFile: 'obsolete/installer-probe..txt',
              disposableAccount: true,
              nativeWindowsX64: true,
              command: fake.command,
              registryFactory: () {
                opened = true;
                return fake;
              },
            ),
            throwsA(same(denied)),
          );
          expect(opened, isFalse);
        },
        fseGetTypeSync: (_, _) => FileSystemEntityType.notFound,
        createDirectory: (_) => _DeniedDirectory(denied),
      );
    },
  );
}

final class _DeniedDirectory implements Directory {
  _DeniedDirectory(this.error);
  final FileSystemException error;
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => throw error;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
