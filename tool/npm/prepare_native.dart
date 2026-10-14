// Maintainer-only prepublication preparation; never reachable from the launcher.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ci/installed_command_recorder.dart';
import '../release/archive_input.dart';
import 'installed_identity.dart';
import 'native_preparation_command.dart';

Future<void> prepareNpmNative({
  required Directory wrapper,
  required Directory cache,
  required String target,
  required Map<String, Object?> receipt,
  required File archive,
  required File node,
  required Map<String, String> environment,
  required InstalledCommandRecorder recorder,
  required Directory workingDirectory,
}) async {
  final descriptor = await readInstalledNpmDescriptor(wrapper, receipt);
  final pin = (descriptor['targets'] as Map)[target] as Map;
  if (pin['size'] is! int ||
      pin['sha256'] is! String ||
      FileSystemEntity.typeSync(cache.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw StateError(
      'Private native preparation needs pinned input and a fresh owned cache',
    );
  }
  await withArchiveInput(archive, (snapshot) async {
    // The shared production owner admits the pinned manifest, every payload
    // entry and executable before extraction/publication. Only its downloader
    // is replaced here with a copy from this separately admitted snapshot.
    await recorder.capture(
      [
        node.path,
        '--eval',
        npmNativePreparationProgram,
        p.join(wrapper.path, 'bin', 'cache.cjs'),
        p.join(wrapper.path, 'acquisition.json'),
        target,
        cache.path,
        snapshot.file.path,
      ],
      environment: environment,
      workingDirectory: workingDirectory.path,
      timeout: const Duration(seconds: 150),
    );
    await inspectNpmNativeCache(
      wrapper: wrapper,
      cache: cache,
      target: target,
      receipt: receipt,
    );
  }, expected: (size: pin['size'] as int, sha256: pin['sha256'] as String));
}
