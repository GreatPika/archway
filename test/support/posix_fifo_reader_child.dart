// Live nonblocking FIFO reader for the source export rejection check.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:posix/posix.dart' as posix;

import 'native_file_fixtures.dart';

Future<void> main(List<String> arguments) async {
  if (!(Platform.isLinux && Abi.current() == Abi.linuxX64 ||
      Platform.isMacOS && Abi.current() == Abi.macosArm64)) {
    throw UnsupportedError('FIFO reader requires Linux x64 or macOS arm64');
  }
  if (arguments.length != 1 || arguments.single.contains('\x00')) {
    throw ArgumentError('Expected one NUL-free FIFO path');
  }
  final path = arguments.single;
  final libc = DynamicLibrary.process();
  final errno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
      );
  final open = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  createNonregularResource(path);
  final name = path.toNativeUtf8();
  int fd;
  try {
    // O_RDONLY is zero; O_NONBLOCK differs between Linux and Darwin.
    fd = open(name, Platform.isMacOS ? 0x4 : 0x800);
    if (fd < 0) {
      final code = errno().value;
      throw FileSystemException(
        'open FIFO reader',
        path,
        OSError('POSIX', code),
      );
    }
  } finally {
    malloc.free(name);
  }
  try {
    stdout.writeln('ready');
    await stdout.flush();
    if (stdin.readLineSync() != 'inspect') {
      throw StateError('Expected inspect handshake');
    }
    stdout.writeln(posix.read(fd, 65536).length);
    await stdout.flush();
  } finally {
    // Consume the descriptor once, including on close failure.
    if (posix.close(fd) != 0) {
      final code = errno().value;
      throw FileSystemException(
        'close FIFO reader',
        path,
        OSError('POSIX', code),
      );
    }
  }
}
