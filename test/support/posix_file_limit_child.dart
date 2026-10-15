// Developer-only inherited file-size fault for the supported native POSIX ABIs.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Linux x64 and Darwin arm64: struct rlimit is two unsigned 64-bit rlim_t values.
final class _FileSizeLimit extends Struct {
  @Uint64()
  external int current;
  @Uint64()
  external int maximum;
}

void main(List<String> arguments) {
  if (!(Platform.isLinux && Abi.current() == Abi.linuxX64 ||
      Platform.isMacOS && Abi.current() == Abi.macosArm64)) {
    throw UnsupportedError(
      'File-limit fixture requires Linux x64 or macOS arm64',
    );
  }
  if (arguments.isEmpty ||
      !File(arguments.first).isAbsolute ||
      arguments.any((argument) => argument.contains('\x00'))) {
    throw ArgumentError(
      'Expected an absolute executable and NUL-free arguments',
    );
  }
  final libc = DynamicLibrary.process();
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
      );
  final signal = libc
      .lookupFunction<
        Pointer<Void> Function(Int32, Pointer<Void>),
        Pointer<Void> Function(int, Pointer<Void>)
      >('signal');
  final setLimit = libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<_FileSizeLimit>),
        int Function(int, Pointer<_FileSizeLimit>)
      >('setrlimit');
  final execute = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>)
      >('execv');
  final limit = calloc<_FileSizeLimit>();
  final argv = calloc<Pointer<Utf8>>(arguments.length + 1);
  try {
    for (var index = 0; index < arguments.length; index++) {
      argv[index] = arguments[index].toNativeUtf8();
    }
    // Both supported ABIs define SIGXFSZ=25, SIG_IGN=(handler)1, RLIMIT_FSIZE=1.
    if (signal(25, Pointer<Void>.fromAddress(1)) ==
        Pointer<Void>.fromAddress(-1)) {
      throw OSError('signal(SIGXFSZ, SIG_IGN)', errno().value);
    }
    limit.ref
      ..current = 1
      ..maximum = 1;
    if (setLimit(1, limit) != 0)
      throw OSError('setrlimit(RLIMIT_FSIZE)', errno().value);
    // No proxy process: the caller still owns and can reap this exact PID.
    execute(argv[0], argv);
    throw OSError('execv ${arguments.first}', errno().value);
  } finally {
    for (var index = 0; index < arguments.length; index++) {
      malloc.free(argv[index]);
    }
    calloc.free(argv);
    calloc.free(limit);
  }
}
