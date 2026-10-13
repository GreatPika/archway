import 'dart:io';

import 'windows_installer_lifecycle.dart';
import 'windows_installer_registry.dart';

final class FakeWindowsInstallation implements WindowsInstallerRegistry {
  static const root = r'C:\Users\probe\Programs\Archway';
  WindowsRegistryValue? path = WindowsRegistryValue.raw(7, [255, 0, 1]);
  WindowsInstallerOwner? owner;
  final executables = <String>[];
  final calls = <List<String>>[];
  final budgets = <Duration>[];
  final reports = <String>[];
  Duration now = Duration.zero;
  void Function()? onSleep;
  void Function()? onReadOwner;
  void Function(WindowsRegistryValue?)? onWritePath;
  Future<WindowsInstallerCommandResult> Function()? onCommand;
  int registryOpens = 0;
  bool rootExists = false;

  WindowsInstallerLifecycle open({
    bool nativeWindowsX64 = true,
    bool disposableAccount = true,
    String staleFile = 'obsolete/installer-probe..txt',
  }) => WindowsInstallerLifecycle(
    root: root,
    staleFile: staleFile,
    disposableAccount: disposableAccount,
    nativeWindowsX64: nativeWindowsX64,
    registryFactory: () {
      registryOpens++;
      return this;
    },
    command: command,
    rootExists: () => rootExists,
    listUninstallers: () => List.of(executables),
    monotonicNow: () => now,
    sleep: (delay) async {
      now += delay;
      onSleep?.call();
    },
    reportSecondary: reports.add,
  );

  void installed() {
    owner = WindowsInstallerOwner(root: WindowsRegistryValue.string(root));
    executables.add('$root\\unins000.exe');
  }

  void removed() {
    owner = null;
    executables.clear();
  }

  Future<WindowsInstallerCommandResult> command(
    List<String> arguments, {
    required Duration timeout,
    int? expectedExit = 0,
    String? workingDirectory,
    Map<String, String>? environment,
    File? windowsStdinFile,
  }) async {
    calls.add(List.of(arguments));
    budgets.add(timeout);
    return onCommand == null
        ? (exitCode: 0, stdout: <int>[], stderr: <int>[])
        : await onCommand!();
  }

  @override
  WindowsRegistryValue? readPath() => path;
  @override
  void writePath(WindowsRegistryValue? value) {
    onWritePath?.call(value);
    path = value;
  }

  @override
  WindowsInstallerOwner? readOwner() {
    onReadOwner?.call();
    return owner;
  }
}
