import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'support/windows_installer_registry.dart';

void main() {
  test(
    'raw Path snapshots retain private bytes and distinguish owner absence',
    () {
      final bytes = [255, 0, 1];
      final snapshot = WindowsRegistryValue.raw(7, bytes);
      bytes[0] = 0;
      expect(snapshot, WindowsRegistryValue.raw(7, [255, 0, 1]));
      expect(snapshot, isNot(WindowsRegistryValue.raw(1, [255, 0, 1])));
      expect(snapshot, isNot(WindowsRegistryValue.raw(7, [0, 0, 1])));
      expect(snapshot.toString(), 'WindowsRegistryValue(<private>)');
      expect(() => snapshot.stringValue, throwsFormatException);
      final owner = WindowsInstallerOwner();
      expect(owner, isNotNull);
      expect(owner.root, isNull);
      expect(owner.pathToken, isNull);
      expect(
        () => WindowsInstallerOwner(root: snapshot),
        throwsFormatException,
      );
      expect(
        () => WindowsInstallerOwner(pathToken: snapshot),
        throwsFormatException,
      );
    },
  );
  test(
    'native registry rejects unsupported ABI before opening keys',
    () {
      expect(() => NativeWindowsInstallerRegistry(), throwsUnsupportedError);
    },
    skip: Platform.isWindows && Abi.current() == Abi.windowsX64
        ? 'Non-native Windows registry host control'
        : false,
  );
  test('malformed strings fail without exposing private bytes', () {
    for (final value in [
      WindowsRegistryValue.raw(7, [65, 0, 0, 0]),
      WindowsRegistryValue.raw(1, [65]),
      WindowsRegistryValue.raw(1, [65, 0, 0, 0, 66, 0]),
      WindowsRegistryValue.raw(1, [0, 0xd8]),
      WindowsRegistryValue.raw(1, [0, 0xdc]),
    ]) {
      expect(() => value.stringValue, throwsFormatException);
    }
    expect(
      () => WindowsRegistryValue.string('a\u0000b'),
      throwsFormatException,
    );
    expect(
      () => WindowsRegistryValue.string('bad', type: 7),
      throwsFormatException,
    );
  });
  test(
    'synthetic registry strings preserve UTF-16 bytes and never expand Path',
    () {
      final value = WindowsRegistryValue.string(
        '%SystemRoot%;café;🚀',
        type: 2,
      );
      expect(value.type, 2);
      expect(value.stringValue, '%SystemRoot%;café;🚀');
      expect(
        WindowsRegistryValue.string('A'),
        WindowsRegistryValue.raw(1, [0x41, 0, 0, 0]),
      );
      expect(
        WindowsRegistryValue.string('🚀', type: 2),
        WindowsRegistryValue.raw(2, [0x3d, 0xd8, 0x80, 0xde, 0, 0]),
      );
      final owner = WindowsInstallerOwner(root: value);
      expect(owner.root?.stringValue, '%SystemRoot%;café;🚀');
      expect(owner.pathToken, isNull);
      expect(WindowsRegistryValue.raw(1, [0x41, 0, 0, 0]).stringValue, 'A');
      expect(WindowsRegistryValue.raw(1, [0x41, 0]).stringValue, 'A');
      expect(WindowsRegistryValue.raw(1, []).stringValue, '');
      expect(value.toString(), isNot(contains('SystemRoot')));
    },
  );
}
