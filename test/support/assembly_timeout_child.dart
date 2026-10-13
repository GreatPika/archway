// Controlled timeout only: the private fixture does not build an installation.
import 'dart:io';

import '../../tool/ci/native_assembly_init_probe.dart';

Future<void> main(List<String> args) async {
  await assembleNativeInstallation(
    Directory(args[0]),
    Directory(args[1]),
    Directory(args[2]),
    dart: File(Platform.resolvedExecutable),
    timeout: const Duration(seconds: 3),
  );
}
