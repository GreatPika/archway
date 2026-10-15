// Developer-only Linux permission fixture. execv preserves the owned child PID.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

void main(List<String> arguments) {
  if (!Platform.isLinux) throw UnsupportedError('Linux permission fixture');
  if (arguments.isEmpty ||
      !File(arguments.first).isAbsolute ||
      arguments.any((argument) => argument.contains('\x00'))) {
    throw ArgumentError(
      'Expected an absolute executable and NUL-free arguments',
    );
  }
  final libc = DynamicLibrary.process();
  final uid = libc.lookupFunction<Uint32 Function(), int Function()>('getuid');
  final effectiveUid = libc.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  );
  final setUid = libc.lookupFunction<Int32 Function(Uint32), int Function(int)>(
    'setuid',
  );
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  final execute = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)
      >('execv');
  final argv = calloc<Pointer<Utf8>>(arguments.length + 1);
  try {
    for (var index = 0; index < arguments.length; index++) {
      argv[index] = arguments[index].toNativeUtf8();
    }
    // Match the original preexec_fn: change only UID, never GID or groups.
    if (uid() == 0) {
      if (setUid(65534) != 0) throw OSError('setuid(65534)', errno().value);
      if (uid() != 65534 || effectiveUid() != 65534) {
        throw StateError('Permission fixture did not drop to uid 65534');
      }
    }
    execute(argv[0], argv);
    throw OSError('execv ${arguments.first}', errno().value);
  } finally {
    for (var index = 0; index < arguments.length; index++) {
      malloc.free(argv[index]);
    }
    calloc.free(argv);
  }
}
