// Thin SDK launcher; policy, JSON and command behavior belong to the native core.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_cache.dart';

Future<int> launchPubNative(
  Map<String, Object?> descriptor,
  List<String> arguments,
) async {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  try {
    final target = switch (Abi.current()) {
      Abi.linuxX64 => 'linux-x64',
      Abi.macosArm64 => 'macos-arm64',
      Abi.windowsX64 => 'windows-x64',
      _ => throw UnsupportedError(
        'Unsupported native target: ${Abi.current()}',
      ),
    };
    final environment = Platform.environment;
    String requiredDirectory(String name) {
      final value = environment[name];
      if (value == null || value.isEmpty || !p.isAbsolute(value)) {
        throw FormatException('Missing absolute user cache location: $name');
      }
      return value;
    }

    final base = Platform.isWindows
        ? requiredDirectory('LOCALAPPDATA')
        : Platform.isMacOS
        ? p.join(requiredDirectory('HOME'), 'Library', 'Caches')
        : environment['XDG_CACHE_HOME']?.isNotEmpty == true
        ? requiredDirectory('XDG_CACHE_HOME')
        : p.join(requiredDirectory('HOME'), '.cache');
    final binary = await acquirePubNative(
      descriptor,
      target,
      Directory(p.join(base, 'archway-pub')),
    );
    Process? child;
    final pending = <ProcessSignal>[];
    if (!Platform.isWindows) {
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
        subscriptions.add(
          signal.watch().listen((_) {
            final running = child;
            if (running == null) {
              pending.add(signal);
            } else {
              running.kill(signal);
            }
          }),
        );
      }
    }
    child = await Process.start(
      binary.path,
      arguments,
      mode: ProcessStartMode.inheritStdio,
      runInShell: false,
    );
    for (final signal in pending) {
      child.kill(signal);
    }
    return await child.exitCode;
  } catch (error) {
    stderr.writeln('archway pub launcher: $error');
    return 126;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
