// Run directly in a fresh VM: no other helper may warm Win32 error capture.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'windows_process_pipes.dart';

Future<void> main() async {
  if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
    throw UnsupportedError('Native Windows x64 required');
  }
  await prepareAndClose(); // Cold size probe.
  await prepareAndClose(); // Same behavior after the helper is warm.
}

Future<void> prepareAndClose() async {
  final startup = calloc<Uint8>(112); // STARTUPINFOEXW x64.
  WindowsProcessPipes? pipes;
  try {
    pipes = WindowsProcessPipes();
    pipes.prepareStartup(startup);
    if (startup.cast<Uint32>().value != 112 ||
        (startup + 60).cast<Uint32>().value != 0x101 ||
        (startup + 104).cast<Pointer<Void>>().value == nullptr) {
      throw StateError('Cold startup did not install its handle list');
    }
    for (final offset in [80, 88, 96]) {
      if ((startup + offset).cast<Pointer<Void>>().value == nullptr) {
        throw StateError('Cold startup omitted a standard handle');
      }
    }
    // No process is launched: releasing all writer ends must yield actual EOF.
    pipes.finishSpawn();
    final result = await pipes.communicate(() => 0, const Duration(seconds: 5));
    if (result.stdout.isNotEmpty || result.stderr.isNotEmpty) {
      throw StateError('Unspawned pipes unexpectedly contained output');
    }
  } finally {
    try {
      pipes?.close();
    } finally {
      calloc.free(startup);
    }
  }
}
