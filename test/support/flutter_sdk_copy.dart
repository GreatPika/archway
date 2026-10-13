// Fixture-only hardlinked SDK copy. Unlink every copied file before mutating it.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

void copyFlutterSdk(Directory source, Directory destination) {
  if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Flutter fixture destination exists',
      destination.path,
    );
  }
  destination.createSync();
  for (final entity in source.listSync(followLinks: false)) {
    if (p.basename(entity.path) == '.git') continue;
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      copyFlutterSdk(entity, Directory(target));
    } else if (entity is Link) {
      Link(target).createSync(entity.targetSync());
    } else {
      _hardlink(entity.path, target);
    }
  }
}

void _hardlink(String source, String destination) {
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final link = kernel
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
          int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
        >('CreateHardLinkW');
    using((arena) {
      if (link(
            destination.toNativeUtf16(allocator: arena),
            source.toNativeUtf16(allocator: arena),
            nullptr,
          ) ==
          0) {
        throw FileSystemException(
          'Hardlink Flutter fixture',
          destination,
          OSError('Win32', error()),
        );
      }
    });
  } else {
    final libc = DynamicLibrary.process();
    final error = libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          Platform.isMacOS ? '__error' : '__errno_location',
        );
    final link = libc
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('link');
    using((arena) {
      if (link(
            source.toNativeUtf8(allocator: arena),
            destination.toNativeUtf8(allocator: arena),
          ) !=
          0) {
        throw FileSystemException(
          'Hardlink Flutter fixture',
          destination,
          OSError('POSIX', error().value),
        );
      }
    });
  }
}

void makeFlutterLauncherExecutable(File launcher) {
  if (Platform.isWindows) return;
  final libc = DynamicLibrary.process();
  final error = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
      );
  final chmod = Platform.isMacOS
      ? libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint16),
          int Function(Pointer<Utf8>, int)
        >('chmod')
      : libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)
        >('chmod');
  using((arena) {
    if (chmod(launcher.path.toNativeUtf8(allocator: arena), 0x1ed) != 0) {
      throw FileSystemException(
        'chmod Flutter fixture launcher',
        launcher.path,
        OSError('POSIX', error().value),
      );
    }
  });
}
