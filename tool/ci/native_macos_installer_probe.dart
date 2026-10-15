// Maintainer-only lifecycle: native execution belongs on disposable macOS CI.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import 'installer_command_recorder.dart';

typedef InstallerRun = Future<String> Function(
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  int expectedExit,
});

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<Map<String, Object?>> runMacosInstaller({
  required Directory repository,
  required File builderDart,
  required Directory bundle,
  required String version,
  required Directory output,
  required Future<Map<String, Object?>> Function(File, Directory) inspect,
}) async {
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
    throw const FormatException(
      'Installer lifecycle requires native macOS arm64',
    );
  }
  final recorder = InstallerCommandRecorder(
    output: output.absolute,
    prefix: 'macos',
    timeout: const Duration(seconds: 240),
  );
  return exerciseMacosInstaller(
    repository: repository,
    builderDart: builderDart,
    bundle: bundle,
    version: version,
    output: output,
    installed: Directory('/usr/local/lib/archway'),
    command: File('/usr/local/bin/archway'),
    compiler: File('/usr/bin/pkgbuild'),
    temporaryParent: Directory.systemTemp,
    run: recorder.run,
    commands: () => recorder.commands,
    inspect: inspect,
  );
}

/// Command/filesystem fixture seam only; the native entrypoint above owns its
/// non-injectable host gate. Synthetic results are not installation acceptance.
Future<Map<String, Object?>> exerciseMacosInstaller({
  required Directory repository,
  required File builderDart,
  required Directory bundle,
  required String version,
  required Directory output,
  required Directory installed,
  required File command,
  required File compiler,
  required Directory temporaryParent,
  required InstallerRun run,
  required List<Map<String, Object?>> Function() commands,
  required Future<Map<String, Object?>> Function(File, Directory) inspect,
  Future<void> Function(Directory)? deleteTemporary,
}) async {
  if (!p.isAbsolute(builderDart.path) || !await builderDart.exists()) {
    throw const FormatException(
      'Builder Dart must be an explicit absolute executable',
    );
  }
  if (await _exists(installed.path) || await _exists(command.path)) {
    throw const FormatException(
      'Disposable macOS host already contains Archway files',
    );
  }
  if (await _exists(output.path))
    throw const FormatException('Output must be fresh');
  output = output.absolute;
  bundle = bundle.absolute;
  repository = repository.absolute;
  final canonicalBundle = await bundle.resolveSymbolicLinks();
  final canonicalOutput = await _resolvedOutput(output.path);
  if (p.equals(canonicalBundle, canonicalOutput) ||
      p.isWithin(canonicalBundle, canonicalOutput)) {
    throw const FormatException('Output must be outside the input bundle');
  }
  await output.create(recursive: true);
  // pkgutil's documented absence status is 1. Other failures are not absence.
  await run([
    '/usr/sbin/pkgutil',
    '--pkg-info',
    'org.archway.cli',
  ], expectedExit: 1);
  final compilerIdentity = {
    'path': compiler.path,
    'sha256': await _digest(compiler),
    'version':
        'Apple pkgbuild bundled with host (no compiler-version query):\n${await run(['/usr/bin/sw_vers'])}',
  };
  final artifact = File(
    p.join(output.path, 'archway-$version-macos-arm64-unsigned.pkg'),
  );
  final base = Directory(
    await (await temporaryParent.createTemp('archway pkg '))
        .resolveSymbolicLinks(),
  );
  late Map<String, Object?> oldIdentity;
  late Map<String, Object?> commandResult;
  var failed = false;
  try {
    final old = Directory(p.join(base.path, 'test-only-old-bundle'));
    await _copyBundle(bundle, old);
    const staleName = 'obsolete/installer-probe..txt';
    final stale = File(p.join(old.path, staleName));
    await stale.parent.create();
    await stale.writeAsString('Test-only previous-generation owned file.\n');
    posix.chmod(stale.path, '644');
    final manifestFile = File(p.join(old.path, 'manifest.json'));
    final manifest =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    manifest['version'] = '0.0.0';
    (manifest['files'] as Map)[staleName] = {
      'mode': 0x1a4,
      'size': await stale.length(),
      'sha256': await _digest(stale),
    };
    await manifestFile.writeAsString('${jsonEncode(manifest)}\n');
    final oldBuild = Directory(p.join(base.path, 'old-build'));
    final finalBuild = Directory(p.join(base.path, 'final-build'));
    for (final pair in [(old, oldBuild), (bundle, finalBuild)]) {
      await run([
        builderDart.path,
        p.join(repository.path, 'tool/installers/macos/build.dart'),
        '--bundle',
        pair.$1.path,
        '--output',
        pair.$2.path,
      ]);
    }
    final oldPkg = File(
      p.join(oldBuild.path, 'archway-0.0.0-macos-arm64-unsigned.pkg'),
    );
    await File(p.join(finalBuild.path, p.basename(artifact.path)))
        .copy(artifact.path);
    oldIdentity = {
      'version': '0.0.0',
      'test_only': true,
      'removed_file': staleName,
      'manifest_sha256': await _digest(manifestFile),
      'artifact_sha256': await _digest(oldPkg),
    };
    final fallback = File(
      p.join(finalBuild.path, 'root/usr/local/lib/archway/uninstall.sh'),
    );
    final uninstallDigest = await _digest(fallback);
    final foreign = File(p.join(installed.path, 'user-notes.txt'));
    final marker = File(p.join(base.path, 'foreign-marker.txt'));
    await marker.writeAsString('preserve foreign file');
    final project = File(
      p.join(base.path, 'foreign project/architecture.yaml'),
    );
    await project.parent.create();
    await project.writeAsString('preserve project');
    var installAttempted = false;
    var primaryFailure = false;
    try {
      installAttempted = true;
      await run([
        'sudo',
        '-n',
        '/usr/sbin/installer',
        '-pkg',
        oldPkg.path,
        '-target',
        '/',
      ]);
      if (await File(p.join(installed.path, staleName)).readAsString() !=
          await stale.readAsString()) {
        throw const FormatException(
          'Old pkg did not install stale-file control',
        );
      }
      if (await _exists(foreign.path))
        throw const FormatException('Foreign marker already exists');
      await run(['sudo', '-n', '/bin/cp', marker.path, foreign.path]);
      await run([
        'sudo',
        '-n',
        '/usr/sbin/installer',
        '-pkg',
        artifact.path,
        '-target',
        '/',
      ]);
      if (await _exists(p.join(installed.path, staleName))) {
        throw const FormatException('Final pkg retained obsolete owned bytes');
      }
      final expected =
          (jsonDecode(
                await File(p.join(bundle.path, 'manifest.json')).readAsString(),
              ) as Map)['files']
              as Map;
      for (final name in expected.keys.cast<String>()) {
        final path = File(p.join(installed.path, name));
        if (await FileSystemEntity.type(path.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await _digest(path) != (expected[name] as Map)['sha256']) {
          throw FormatException('Installed pkg payload differs: $name');
        }
      }
      if (await _digest(File(p.join(installed.path, 'manifest.json'))) !=
          await _digest(File(p.join(bundle.path, 'manifest.json')))) {
        throw const FormatException('Installed pkg manifest differs');
      }
      if (await FileSystemEntity.type(command.path, followLinks: false) !=
              FileSystemEntityType.link ||
          await Link(command.path).target() !=
              p.join(installed.path, 'bin/macos-arm64/archway')) {
        throw const FormatException(
          'Installed pkg command registration differs',
        );
      }
      commandResult = await inspect(command, installed);
      await _uninstall(installed, fallback, uninstallDigest, run);
      if (await _exists(command.path))
        throw const FormatException('pkg uninstall retained owned command');
      for (final name in [
        ...expected.keys,
        'manifest.json',
        'uninstall.sh',
        '.archway-owned.sha256',
      ]) {
        if (await _exists(p.join(installed.path, name as String))) {
          throw FormatException('pkg uninstall retained owned payload: $name');
        }
      }
      if (await foreign.readAsString() != 'preserve foreign file' ||
          await project.readAsString() != 'preserve project') {
        throw const FormatException('pkg uninstall changed foreign files');
      }
      await run([
        '/usr/sbin/pkgutil',
        '--pkg-info',
        'org.archway.cli',
      ], expectedExit: 1);
      await _removeMarker(installed, foreign, run);
    } catch (_) {
      primaryFailure = true;
      rethrow;
    } finally {
      if (installAttempted && await _exists(installed.path)) {
        try {
          await _uninstall(installed, fallback, uninstallDigest, run);
          await _removeMarker(installed, foreign, run);
        } catch (error) {
          stderr.writeln(
            'Owned macOS test installation cleanup failed: $error',
          );
          if (!primaryFailure) rethrow;
        }
      }
    }
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    try {
      if (await _exists(base.path)) {
        if (deleteTemporary != null) {
          await deleteTemporary(base);
        } else {
          await base.delete(recursive: true);
        }
      }
    } catch (error) {
      stderr.writeln('Owned macOS temporary cleanup failed: $error');
      if (!failed) rethrow;
    }
  }
  return {
    'artifact': {
      'name': p.basename(artifact.path),
      'sha256': await _digest(artifact),
      'size': await artifact.length(),
    },
    'compiler': compilerIdentity,
    'old_fixture': oldIdentity,
    'cases': [
      'install-old',
      'upgrade-final',
      'installed-command',
      'remove',
      'foreign-preserved',
    ],
    'installed': commandResult,
    'commands': commands(),
  };
}

Future<void> _uninstall(
  Directory installed,
  File fallback,
  String digest,
  InstallerRun run,
) async {
  var script = File(p.join(installed.path, 'uninstall.sh'));
  if (!await _exists(script.path)) script = fallback;
  if (await FileSystemEntity.type(script.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await _digest(script) != digest) {
    throw const FormatException(
      'Refusing cleanup through an unverified standard uninstaller',
    );
  }
  await run(['sudo', '-n', '/bin/sh', script.path]);
}

Future<void> _removeMarker(
  Directory installed,
  File foreign,
  InstallerRun run,
) async {
  if (await FileSystemEntity.type(foreign.path, followLinks: false) ==
          FileSystemEntityType.file &&
      await foreign.readAsString() == 'preserve foreign file') {
    await run(['sudo', '-n', '/bin/rm', foreign.path]);
  }
  if (await FileSystemEntity.type(installed.path, followLinks: false) ==
          FileSystemEntityType.directory &&
      await installed.list().isEmpty) {
    await run(['sudo', '-n', '/bin/rmdir', installed.path]);
  }
}

Future<void> _copyBundle(Directory source, Directory destination) async {
  await destination.create();
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    final path = p.join(
      destination.path,
      p.relative(entry.path, from: source.path),
    );
    if (entry is Directory) {
      await Directory(path).create(recursive: true);
    } else if (entry is File) {
      await File(path).parent.create(recursive: true);
      await entry.copy(path);
      posix.chmod(path, ((await entry.stat()).mode & 0xfff).toRadixString(8));
    } else {
      throw const FormatException(
        'Bundle must contain ordinary files and directories',
      );
    }
  }
}

// Resolve each existing ancestor so a new leaf below an aliased bundle cannot
// create evidence inside the input before the bundle is copied.
Future<String> _resolvedOutput(String path) async {
  if (await _exists(path)) return File(path).resolveSymbolicLinks();
  return p.join(await _resolvedOutput(p.dirname(path)), p.basename(path));
}
