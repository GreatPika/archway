// Build and exercise Debian packages in an owned, isolated dpkg root.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import 'installer_command_recorder.dart';
import 'linux_installer_fixture.dart' show installerRootMarker;

const _stale = 'obsolete/installer-probe..txt';

Future<Map<String, Object?>> runLinuxInstallerProbe({
  required File builderDart,
  required Directory repository,
  required Directory bundle,
  required String version,
  required Directory output,
  required String expectedCommit,
  required List<String> privilege,
  required Future<Map<String, Object?>> Function(File, Directory) inspect,
}) async {
  if (!Platform.isLinux)
    throw UnsupportedError('Linux installer probe requires Linux');
  if (!p.isAbsolute(builderDart.path) || !await builderDart.exists()) {
    throw const FormatException(
      'Explicit absolute builder Dart executable required',
    );
  }
  repository = repository.absolute;
  bundle = bundle.absolute;
  output = output.absolute;
  if (await bundle.resolveSymbolicLinks() != bundle.path ||
      p.equals(bundle.path, output.path) ||
      p.isWithin(bundle.path, output.path)) {
    throw const FormatException(
      'Canonical bundle and external evidence directory required',
    );
  }
  if (await _canonicalMissing(output.path) != output.path) {
    throw const FormatException('Evidence directory must be canonical');
  }
  await output.create(recursive: true);
  if (await output.resolveSymbolicLinks() != output.path) {
    throw const FormatException('Evidence directory must be canonical');
  }
  final recorder = InstallerCommandRecorder(
    output: output,
    prefix: 'linux',
    timeout: const Duration(seconds: 180),
  );
  final compiler = await _compiler();
  final compilerIdentity = <String, Object?>{
    'path': compiler.path,
    'sha256': await _hash(compiler),
    'version': await recorder.run([compiler.path, '--version']),
  };
  final artifact = File(
    p.join(output.path, 'archway-$version-linux-x64-unsigned.deb'),
  );
  final manifestFile = File(p.join(bundle.path, 'manifest.json'));
  final before = await _hash(manifestFile);
  final temp = Directory(
    await (await Directory.systemTemp.createTemp('archway installer '))
        .resolveSymbolicLinks(),
  );
  final token = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  await File(p.join(temp.path, installerRootMarker)).writeAsString(token);
  final system = Directory(p.join(temp.path, 'system'));
  final fixture = p.join(
    repository.path,
    'tool/ci/linux_installer_fixture.dart',
  );
  Future<String> privileged(List<String> args) =>
      recorder.run([...privilege, ...args]);
  Object? primary;
  StackTrace? primaryStack;
  Map<String, Object?>? proof;
  try {
    await system.create();
    final old = Directory(p.join(temp.path, 'test-only-old-bundle'));
    await _copyBundle(bundle, old);
    final stale = File(p.join(old.path, _stale));
    await stale.parent.create(recursive: true);
    await stale.writeAsString('Test-only previous-generation owned file.\n');
    posix.chmod(stale.path, '644');
    final oldManifestFile = File(p.join(old.path, 'manifest.json'));
    final manifest = jsonDecode(
      await oldManifestFile.readAsString(),
    ) as Map<String, dynamic>;
    manifest['version'] = '0.0.0';
    (manifest['files'] as Map)[_stale] = {
      'mode': 420,
      'size': await stale.length(),
      'sha256': await _hash(stale),
    };
    await oldManifestFile.writeAsString('${jsonEncode(manifest)}\n');
    final oldDeb = File(p.join(temp.path, 'test-only-old.deb'));
    for (final pair in [(old, oldDeb), (bundle, artifact)]) {
      await recorder.run([
        builderDart.path,
        p.join(repository.path, 'tool/installers/linux/build.dart'),
        '--bundle',
        pair.$1.path,
        '--expected-commit',
        expectedCommit,
        '--output',
        pair.$2.path,
      ], workingDirectory: repository.path);
    }
    final oldIdentity = <String, Object?>{
      'version': '0.0.0',
      'test_only': true,
      'manifest_sha256': await _hash(oldManifestFile),
      'artifact_sha256': await _hash(oldDeb),
      'removed_file': _stale,
    };
    final dpkg = [
      'dpkg',
      '--root=${system.path}',
      '--log=${p.join(temp.path, 'dpkg.log')}',
      '--force-script-chrootless',
    ];
    await privileged([...dpkg, '--install', oldDeb.path]);
    final installed = Directory(p.join(system.path, 'usr/lib/archway'));
    if (await _hash(File(p.join(installed.path, _stale))) !=
        await _hash(stale)) {
      throw const FormatException(
        'Old installer did not install stale-file control',
      );
    }
    await privileged([builderDart.path, fixture, temp.path, token, 'foreign']);
    await privileged([...dpkg, '--install', artifact.path]);
    if (await _exists(p.join(installed.path, _stale))) {
      throw const FormatException(
        'Final upgrade retained obsolete owned bytes',
      );
    }
    final expected =
        (jsonDecode(await manifestFile.readAsString()) as Map)['files'] as Map;
    for (final entry in expected.entries) {
      final path = p.join(installed.path, entry.key as String);
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await _hash(File(path)) != (entry.value as Map)['sha256']) {
        throw FormatException('Installed Debian payload differs: ${entry.key}');
      }
    }
    if (await _hash(File(p.join(installed.path, 'manifest.json'))) != before) {
      throw const FormatException('Installed manifest differs');
    }
    final command = Link(p.join(system.path, 'usr/bin/archway'));
    if (!await command.exists() ||
        await command.target() != '/usr/lib/archway/bin/linux-x64/archway') {
      throw const FormatException('Installed command registration differs');
    }
    // The absolute registration belongs to the isolated root, never host /usr.
    final result = await inspect(
      File(p.join(installed.path, 'bin/linux-x64/archway')),
      installed,
    );
    await privileged([...dpkg, '--remove', 'archway']);
    if (await _exists(command.path))
      throw const FormatException('Debian uninstall retained owned command');
    for (final name in [...expected.keys, 'manifest.json']) {
      if (await _exists(p.join(installed.path, name as String))) {
        throw FormatException('Debian uninstall retained owned payload: $name');
      }
    }
    if (await File(p.join(installed.path, 'user-notes.txt')).readAsString() !=
            'preserve foreign file' ||
        await File(p.join(system.path, 'home/user/project/architecture.yaml'))
                .readAsString() !=
            'preserve project') {
      throw const FormatException('Debian uninstall changed foreign files');
    }
    await File(p.join(temp.path, 'dpkg.log'))
        .copy(p.join(output.path, 'dpkg.log'));
    if (await _hash(manifestFile) != before)
      throw const FormatException('Verified input manifest changed');
    proof = {
      'artifact': {
        'name': p.basename(artifact.path),
        'sha256': await _hash(artifact),
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
      'installed': result,
    };
  } catch (error, stack) {
    primary = error;
    primaryStack = stack;
  } finally {
    try {
      await privileged([
        builderDart.path,
        fixture,
        temp.path,
        token,
        'cleanup',
      ]);
    } catch (error, stack) {
      primary ??= error;
      primaryStack ??= stack;
    }
  }
  if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
  return {...proof!, 'commands': recorder.commands};
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
Future<bool> _exists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<File> _compiler() async {
  for (final path in (Platform.environment['PATH'] ?? '').split(':')) {
    final file = File(p.join(path, 'dpkg-deb'));
    if (await file.exists() && posix.access(file.path, posix.X_OK) == 0) {
      return File(await file.resolveSymbolicLinks());
    }
  }
  throw const FormatException('Native dpkg-deb compiler is unavailable');
}

Future<void> _copyBundle(Directory source, Directory target) async {
  await target.create();
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final destination = p.join(
      target.path,
      p.relative(entity.path, from: source.path),
    );
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
      posix.chmod(
        destination,
        ((await entity.stat()).mode & 511).toRadixString(8),
      );
    } else {
      throw const FormatException(
        'Bundle copy cannot contain links or special files',
      );
    }
  }
}

Future<String> _canonicalMissing(String path) async {
  final suffix = <String>[];
  var existing = path;
  while (await FileSystemEntity.type(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    suffix.insert(0, p.basename(existing));
    existing = p.dirname(existing);
  }
  return p.joinAll([
    await Directory(existing).resolveSymbolicLinks(),
    ...suffix,
  ]);
}
