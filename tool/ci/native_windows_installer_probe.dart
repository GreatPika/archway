// Real Inno builds and disposable-account lifecycle; never provisions tools.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import '../release/archive_input.dart';
import 'installer_command_recorder.dart';
import 'release_execution_receipts.dart';
import 'windows_installer_scenarios.dart';

const windowsInstallerStaleFile = 'obsolete/installer-probe..txt';

Future<Map<String, Object?>> runWindowsInstallerProbe({
  required File builderDart,
  required Directory repository,
  required Directory bundle,
  required Directory output,
  required bool disposableAccount,
  required Future<Map<String, Object?>> Function(File, Directory) inspect,
}) async {
  if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
    throw UnsupportedError(
      'Native Windows x64 required; no acceptance measured',
    );
  }
  if (!disposableAccount) throw ArgumentError('Disposable account required');
  bundle = bundle.absolute;
  output = output.absolute;
  repository = repository.absolute;
  await validateWindowsInstallerOutput(bundle, output);
  if (!p.isAbsolute(builderDart.path) || !await builderDart.exists()) {
    throw ArgumentError('Explicit absolute builder Dart executable required');
  }
  final programFiles = Platform.environment['ProgramFiles(x86)'];
  if (programFiles == null)
    throw StateError('Preinstalled Inno Setup required');
  final compiler = File(p.join(programFiles, 'Inno Setup 6', 'ISCC.exe'));
  readOrdinaryBytes(compiler);
  final before = snapshotWindowsInstallerBundle(bundle);
  final manifest = jsonDecode(
    File(p.join(bundle.path, 'manifest.json')).readAsStringSync(),
  ) as Map;
  if (manifest['version'] != '0.1.0') {
    throw const FormatException(
      'Final installer requires verified 0.1.0 bundle',
    );
  }
  await output.create(recursive: true);
  final recorder = InstallerCommandRecorder(
    output: output,
    prefix: 'windows',
    timeout: const Duration(seconds: 240),
  );
  final temp = Directory(
    await (await Directory.systemTemp.createTemp('archway installer '))
        .resolveSymbolicLinks(),
  );
  Object? primary;
  try {
    final stdin = File(p.join(temp.path, 'compiler-preflight.iss'));
    await stdin.writeAsString(
      '[Setup]\nAppName=Archway compiler preflight\nAppVersion=0\n'
      'CreateAppDir=no\nUninstallable=no\nOutput=no\n',
    );
    final preflight = await recorder.capture([
      compiler.path,
      '/O-',
      '-',
    ], windowsStdinFile: stdin);
    final compilerIdentity = {
      'path': compiler.path,
      'sha256': _hash(compiler),
      'version': windowsInstallerCompilerVersion(preflight.stdout),
    };
    final old = Directory(p.join(temp.path, 'test-only-old-bundle'));
    await prepareWindowsInstallerOldFixture(bundle, old);
    for (final pair in [(old, 'old', '0.0.0'), (bundle, 'final', '0.1.0')]) {
      final inputs = p.join(temp.path, '${pair.$2}-input');
      await recorder.run([
        builderDart.path,
        p.join(repository.path, 'tool/installers/windows/prepare.dart'),
        pair.$1.path,
        inputs,
      ], workingDirectory: repository.path);
      await recorder.run([
        compiler.path,
        '/DAppVersion=${pair.$3}',
        '/DOutputDir=${pair.$2 == 'old' ? p.join(temp.path, 'old-artifact') : output.path}',
        p.join(inputs, 'archway.iss'),
      ]);
    }
    final oldExe = File(
      p.join(temp.path, 'old-artifact/archway-0.0.0-windows-x64-unsigned.exe'),
    );
    final artifact = File(
      p.join(output.path, 'archway-0.1.0-windows-x64-unsigned.exe'),
    );
    final oldIdentity = {
      'version': '0.0.0',
      'test_only': true,
      'removed_file': windowsInstallerStaleFile,
      'manifest_sha256': _hash(File(p.join(old.path, 'manifest.json'))),
      'artifact_sha256': await withArchiveInput(
        oldExe,
        (input) async => input.sha256,
      ),
    };
    final receipt = await runWindowsInstallerScenarios(
      oldInstaller: oldExe,
      finalInstaller: artifact,
      staleFile: windowsInstallerStaleFile,
      disposableAccount: disposableAccount,
      command: recorder.capture,
      inspect: (binary, installed) async {
        for (final entry in before.entries) {
          if (_hash(File(p.join(installed.path, entry.key))) != entry.value) {
            throw StateError('Installed Windows payload differs: ${entry.key}');
          }
        }
        return inspect(binary, installed);
      },
    );
    if (!sameJson(before, snapshotWindowsInstallerBundle(bundle))) {
      throw StateError('Verified bundle bytes changed');
    }
    return {
      'artifact': await withArchiveInput(
        artifact,
        (input) async => {
          'name': p.basename(artifact.path),
          'sha256': input.sha256,
          'size': input.size,
        },
      ),
      'compiler': compilerIdentity,
      'old_fixture': oldIdentity,
      ...receipt,
      'commands': recorder.commands,
    };
  } catch (error) {
    primary = error;
    rethrow;
  } finally {
    try {
      await temp.delete(recursive: true);
    } catch (error) {
      if (primary == null) rethrow;
      try {
        stderr.writeln(
          'Owned Windows installer temporary cleanup failed (${error.runtimeType})',
        );
      } catch (_) {
        // A diagnostic failure must not replace the original installer failure.
      }
    }
  }
}

// Shared admission runs before compiler lookup or evidence-directory mutation.
Future<void> validateWindowsInstallerOutput(
  Directory bundle,
  Directory output,
) async {
  final payload = await bundle.resolveSymbolicLinks();
  var ancestor = output.absolute;
  final missing = <String>[];
  while (await FileSystemEntity.type(ancestor.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    missing.insert(0, p.basename(ancestor.path));
    ancestor = ancestor.parent;
  }
  final prospective = p.joinAll([
    await ancestor.resolveSymbolicLinks(),
    ...missing,
  ]);
  if (prospective != output.absolute.path ||
      p.equals(payload, prospective) ||
      p.isWithin(payload, prospective) ||
      await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw const FormatException(
      'Installer output must be fresh, canonical and outside bundle',
    );
  }
}

Map<String, String> snapshotWindowsInstallerBundle(Directory bundle) {
  final result = <String, String>{};
  for (final entry in bundle.listSync(recursive: true, followLinks: false)) {
    final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) continue;
    if (type != FileSystemEntityType.file)
      throw StateError('Aliased bundle member');
    result[p.relative(entry.path, from: bundle.path).replaceAll(r'\', '/')] =
        _hash(File(entry.path));
  }
  return result;
}

Future<void> prepareWindowsInstallerOldFixture(
  Directory bundle,
  Directory old,
) async {
  if (FileSystemEntity.typeSync(
        p.join(bundle.path, 'obsolete'),
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound) {
    throw StateError('Final bundle conflicts with obsolete fixture directory');
  }
  final before = snapshotWindowsInstallerBundle(bundle);
  await old.create();
  for (final name in before.keys) {
    final target = File(p.join(old.path, name));
    await target.parent.create(recursive: true);
    await File(p.join(bundle.path, name)).copy(target.path);
  }
  final stale = File(p.join(old.path, windowsInstallerStaleFile));
  await stale.parent.create(recursive: true);
  await stale.writeAsString('Test-only previous-generation owned file.\n');
  final file = File(p.join(old.path, 'manifest.json'));
  final manifest = jsonDecode(await file.readAsString()) as Map;
  manifest['version'] = '0.0.0';
  (manifest['files'] as Map)[windowsInstallerStaleFile] = {
    'mode': 420,
    'size': await stale.length(),
    'sha256': _hash(stale),
  };
  await file.writeAsString('${jsonEncode(manifest)}\n');
}

String windowsInstallerCompilerVersion(List<int> output) {
  final lines = const LineSplitter()
      .convert(utf8.decode(output, allowMalformed: true))
      .where((line) => line.startsWith('Compiler engine version:'))
      .toList();
  final match = lines.length == 1
      ? RegExp(r'^Compiler engine version: Inno Setup (\d+)\.(\d+)\.(\d+)$')
            .firstMatch(lines.single)
      : null;
  if (match == null)
    throw const FormatException('Invalid Inno compiler engine version');
  final parts = [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  if (parts[0] < 6 || (parts[0] == 6 && parts[1] < 3)) {
    throw const FormatException('Inno Setup 6.3 or newer required');
  }
  return parts.join('.');
}

String _hash(File file) => sha256.convert(readOrdinaryBytes(file)).toString();
