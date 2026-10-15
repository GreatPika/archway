// Acceptance bootstrap only. Exec preserves the child PID and inherited pipes.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:posix/posix.dart' as posix;

void main(List<String> arguments) {
  if (Platform.isWindows ||
      arguments.isEmpty ||
      arguments.any((argument) => argument.contains('\u0000')))
    throw ArgumentError('Expected a POSIX command without NUL');
  if (posix.setsid() != pid) throw StateError('Cannot create fixture session');
  final argv = calloc<Pointer<Utf8>>(arguments.length + 1);
  try {
    for (var i = 0; i < arguments.length; i++) {
      argv[i] = arguments[i].toNativeUtf8();
    }
    posix.native_execv(arguments.first, argv);
    throw OSError('Cannot exec fixture command', posix.errno());
  } finally {
    for (var i = 0; i < arguments.length; i++) malloc.free(argv[i]);
    calloc.free(argv);
  }
}
