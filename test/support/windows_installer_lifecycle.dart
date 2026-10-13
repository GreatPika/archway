// Developer-only ownership and cleanup for the disposable Windows lifecycle.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_installer_registry.dart';

/// Normal return confirms direct exit, owned-job empty, and both output EOFs.
/// Spawn/timeout/unconfirmed cleanup must throw, never return a partial result.
typedef WindowsInstallerCommandResult = ({
  int exitCode,
  List<int> stdout,
  List<int> stderr,
});
typedef WindowsInstallerCommand =
    Future<WindowsInstallerCommandResult> Function(
      List<String> arguments, {
      required Duration timeout,
      int? expectedExit,
      String? workingDirectory,
      Map<String, String>? environment,
      File? windowsStdinFile,
    });

final class WindowsInstallerLifecycle {
  WindowsInstallerLifecycle({
    required this.root,
    required String staleFile,
    required bool disposableAccount,
    required WindowsInstallerCommand command,
    bool? nativeWindowsX64,
    WindowsInstallerRegistry Function()? registryFactory,
    bool Function()? rootExists,
    List<String> Function()? listUninstallers,
    Duration Function()? monotonicNow,
    Future<void> Function(Duration)? sleep,
    void Function(String)? reportSecondary,
  }) : _command = command,
       _uninstallers = listUninstallers ?? (() => _readUninstallers(root)),
       _sleep = sleep ?? Future<void>.delayed {
    if (!(nativeWindowsX64 ??
        (Platform.isWindows && Abi.current() == Abi.windowsX64))) {
      throw UnsupportedError('Installer lifecycle requires native Windows x64');
    }
    if (!disposableAccount)
      throw ArgumentError('Explicit disposable account gate required');
    final parts = staleFile.replaceAll(r'\', '/').split('/');
    if (p.windows.isAbsolute(staleFile) ||
        RegExp(r'[:<>"|?*\x00-\x1f]').hasMatch(staleFile) ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.endsWith('.') ||
              part.endsWith(' '),
        ) ||
        parts.length < 2 ||
        !parts.last.contains('..')) {
      throw ArgumentError(
        'Expected safe relative stale path with parent and literal double dot',
      );
    }
    final normalizedRoot = p.windows.normalize(root);
    if (!p.windows.isAbsolute(root) ||
        p.windows.dirname(normalizedRoot) == normalizedRoot) {
      throw ArgumentError(
        'Expected a non-root absolute Windows installation path',
      );
    }
    if ((rootExists ??
        () =>
            _directoryEntries(p.windows.dirname(root))
                .any((entry) => p.windows.equals(entry.path, root)))()) {
      throw StateError('Disposable account already contains an Archway root');
    }
    registry = (registryFactory ?? NativeWindowsInstallerRegistry.new)();
    if (registry.readOwner() != null) {
      throw StateError('Disposable account already contains installer state');
    }
    _originalPath = registry.readPath();
    _reportSecondary = (message) {
      try {
        (reportSecondary ?? stderr.writeln)(message);
      } catch (_) {
        // Diagnostic-sink failure cannot mask the primary or skip restoration.
        try {
          stderr.writeln(message);
        } catch (_) {}
      }
    };
    final clock = Stopwatch()..start();
    _now = monotonicNow ?? (() => clock.elapsed);
  }

  final String root;
  late final WindowsInstallerRegistry registry;
  late final WindowsRegistryValue? _originalPath;
  late final void Function(String) _reportSecondary;
  final WindowsInstallerCommand _command;
  final List<String> Function() _uninstallers;
  late final Duration Function() _now;
  final Future<void> Function(Duration) _sleep;
  bool _cleanupEligible = false;

  Future<T> run<T>(Future<T> Function() body) async {
    Object? primary;
    try {
      return await body();
    } catch (error) {
      primary = error;
      rethrow;
    } finally {
      if (primary != null && _cleanupEligible) {
        try {
          await uninstall();
        } catch (error) {
          _reportSecondary(
            'Owned installer cleanup failed (${error.runtimeType})',
          );
        }
      }
      try {
        registry.writePath(_originalPath);
      } catch (error) {
        // A registry implementation's error must not print the original Path.
        final message = 'Test Path restoration failed (${error.runtimeType})';
        if (primary == null) throw StateError(message);
        _reportSecondary(message);
      }
    }
  }

  Future<WindowsInstallerCommandResult> install(
    String executable, {
    bool expectSuccess = true,
    int? expectedExit,
  }) async {
    final wasEligible = _cleanupEligible;
    _cleanupEligible = false;
    final result = await _command(
      [executable, ..._silent],
      timeout: const Duration(seconds: 180),
      expectedExit: expectedExit ?? (expectSuccess ? 0 : null),
    );
    if ((result.exitCode == 0) != expectSuccess ||
        (expectedExit != null && result.exitCode != expectedExit)) {
      throw StateError('Unexpected installer exit: ${result.exitCode}');
    }
    if (expectSuccess || wasEligible) {
      _requireOwner();
      _cleanupEligible = true;
    }
    return result;
  }

  Future<WindowsInstallerCommandResult> uninstall({
    bool expectSuccess = true,
  }) async {
    final wasEligible = _cleanupEligible;
    // Clear before launch: any ambiguous capture must never trigger a retry.
    _cleanupEligible = false;
    final executables = _uninstallers();
    if (executables.length != 1) {
      throw StateError('Expected exactly one root uninstaller');
    }
    _requireOwner();
    final started = _now();
    final result = await _command(
      [executables.single, ..._silent],
      timeout: _remaining(started),
      expectedExit: expectSuccess ? 0 : null,
    );
    _remaining(started);
    if (!expectSuccess) {
      if (result.exitCode == 0) throw StateError('Expected installer refusal');
      _requireOwner();
      _remaining(started);
      _cleanupEligible = wasEligible;
      return result;
    }
    if (result.exitCode != 0)
      throw StateError('Unexpected installer exit: ${result.exitCode}');
    while (true) {
      _remaining(started);
      final owner = registry.readOwner();
      if (_uninstallers().isEmpty &&
          (owner == null || (owner.root == null && owner.pathToken == null))) {
        _remaining(started);
        return result;
      }
      final remaining = _remaining(started);
      await _sleep(
        remaining < const Duration(milliseconds: 50)
            ? remaining
            : const Duration(milliseconds: 50),
      );
    }
  }

  Duration _remaining(Duration started) {
    final remaining = const Duration(seconds: 180) - (_now() - started);
    if (remaining <= Duration.zero) {
      throw TimeoutException('Inno uninstall did not complete');
    }
    return remaining;
  }

  void _requireOwner() {
    final ownerRoot = registry.readOwner()?.root?.stringValue;
    if (ownerRoot == null || !p.windows.equals(ownerRoot, root)) {
      throw StateError('Cannot launch with unverified installer ownership');
    }
  }
}

const _silent = ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'];
List<FileSystemEntity> _directoryEntries(String path) {
  try {
    return Directory(path).listSync(followLinks: false);
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode == 2 || error.osError?.errorCode == 3)
      return [];
    rethrow; // Access/query failure is not proof of absence.
  }
}

List<String> _readUninstallers(String root) => [
  for (final entry in _directoryEntries(root))
    if (RegExp(
      r'^unins.*\.exe$',
      caseSensitive: false,
    ).hasMatch(p.basename(entry.path)))
      entry.path,
];
