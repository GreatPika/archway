// Genuine native D/E engineering cases. Requires a disposable Windows account.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../test/support/check_inventory_fixture.dart';
import '../../test/support/native_file_fixtures.dart';
import '../../test/support/windows_installer_lifecycle.dart';
import '../../test/support/windows_installer_registry.dart';
import '../validation/json_values.dart';
import 'release_execution_receipts.dart';

Future<Map<String, Object?>> runWindowsInstallerScenarios({
  required File oldInstaller,
  required File finalInstaller,
  required String staleFile,
  required bool disposableAccount,
  required WindowsInstallerCommand command,
  required Future<Map<String, Object?>> Function(File, Directory) inspect,
}) async {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null) throw StateError('LOCALAPPDATA required');
  final root = Directory(p.join(local, 'Programs', 'Archway'));
  final token = p.join(root.path, 'bin', 'windows-x64');
  final binary = File(p.join(token, 'archway.exe'));
  final lifecycle = WindowsInstallerLifecycle(
    root: root.path,
    staleFile: staleFile,
    disposableAccount: disposableAccount,
    command: command,
  );
  final registry = lifecycle.registry;
  final cases = <String>{};
  Future<void> install() async {
    await lifecycle.install(oldInstaller.absolute.path);
  }

  Future<void> upgrade() async {
    await lifecycle.install(finalInstaller.absolute.path);
  }

  void setPath(String value, int type) =>
      registry.writePath(WindowsRegistryValue.string(value, type: type));
  void requirePath(String value, int type) => _require(
    registry.readPath() == WindowsRegistryValue.string(value, type: type),
    'Synthetic Path bytes/type changed',
  );
  final stale = File(p.join(root.path, staleFile));
  final raw =
      '%SystemRoot%\\System32;${List.generate(250, (i) => 'C:\\unrelated spaced путь $i').join(';')};;';
  Future<void> junction(String path, String target) async {
    await command(
      [
        windowsInventoryCommand(),
        ...windowsInventoryJunctionArguments(path, target),
      ],
      timeout: const Duration(seconds: 180),
      expectedExit: 0,
    );
    try {
      _require(
        windowsReparseMetadata(path).tag == 0xa0000003 &&
            Directory(path).resolveSymbolicLinksSync() ==
                Directory(target).resolveSymbolicLinksSync(),
        'Junction fixture must resolve to the intended target',
      );
    } catch (_) {
      try {
        removeWindowsDirectoryEntry(path);
      } catch (cleanupError) {
        stderr.writeln('Junction fixture cleanup failed: $cleanupError');
      }
      rethrow;
    }
  }

  Future<void> temporary(Future<void> Function(Directory) body) async {
    final directory = await Directory.systemTemp.createTemp(
      'Archway cwd путь ',
    );
    Object? primary;
    try {
      await body(directory);
    } catch (error) {
      primary = error;
      rethrow;
    } finally {
      try {
        await directory.delete(recursive: true);
      } catch (error) {
        if (primary == null) rethrow;
        try {
          stderr.writeln(
            'Owned Windows scenario temporary cleanup failed (${error.runtimeType})',
          );
        } catch (_) {
          // Preserve the native scenario failure even if diagnostics fail.
        }
      }
    }
  }

  return lifecycle.run(() async {
    for (final type in [1, 2]) {
      setPath(raw, type);
      await install();
      cases.add('install-old');
      final expected = '$raw;$token';
      requirePath(expected, type);
      _require(
        registry.readOwner()?.pathToken?.stringValue == token,
        'Installed Path ownership missing',
      );
      final oldFiles = _manifest(root);
      await upgrade();
      cases.add('upgrade-final');
      final newFiles = _manifest(root);
      _require(
        oldFiles.containsKey(staleFile) && !newFiles.containsKey(staleFile),
        'No real stale-file generation transition',
      );
      for (final entry in newFiles.entries) {
        _require(
          _hash(File(p.join(root.path, entry.key))) ==
              (entry.value as Map)['sha256'],
          'Final installed payload differs',
        );
      }
      for (final name in oldFiles.keys.toSet().difference(
        newFiles.keys.toSet(),
      )) {
        _require(!_exists(p.join(root.path, name)), 'Stale owned file remains');
      }
      requirePath(expected, type);
      const later = ';C:\\later unrelated 雪';
      setPath('$expected$later', type);
      final foreign = File(p.join(root.path, 'user-notes.txt'));
      await foreign.writeAsString('preserve me');
      await lifecycle.uninstall();
      cases.add('remove');
      requirePath('$raw$later', type);
      _require(
        await foreign.readAsString() == 'preserve me',
        'Foreign file lost',
      );
      cases.addAll(['foreign-preserved', 'raw-path-registry-types']);
      await foreign.delete();
      await root.delete();
    }
    final prior = '%SystemRoot%\\System32;"${token.toUpperCase()}\\";';
    setPath(prior, 2);
    await install();
    await upgrade();
    requirePath(prior, 2);
    _require(
      registry.readOwner()?.pathToken == null,
      'Adopted preexisting Path token',
    );
    await temporary((directory) async {
      final systemRoot = Platform.environment['SystemRoot'];
      if (systemRoot == null) throw StateError('SystemRoot required');
      final environment = {
        ...Platform.environment,
        'PATH': '$systemRoot\\System32;$token',
      };
      await command(
        [binary.path, '--help'],
        timeout: const Duration(seconds: 180),
        expectedExit: 0,
        workingDirectory: directory.path,
        environment: environment,
      );
      final discovery = await command(
        [p.join(systemRoot, 'System32', 'where.exe'), 'archway'],
        timeout: const Duration(seconds: 180),
        expectedExit: 0,
        workingDirectory: directory.path,
        environment: environment,
      );
      _require(
        utf8
            .decode(discovery.stdout, allowMalformed: true)
            .toLowerCase()
            .contains(token.toLowerCase()),
        'Installed command discovery failed',
      );
    });
    final installed = await inspect(binary, root);
    cases.add('installed-command');
    await lifecycle.uninstall();
    requirePath(prior, 2);
    cases.add('preexisting-path-token');

    await root.create();
    final sentinel = File(p.join(root.path, 'foreign.txt'));
    await sentinel.writeAsString('untouched');
    final before = registry.readPath();
    await lifecycle.install(oldInstaller.path, expectSuccess: false);
    _require(
      await sentinel.readAsString() == 'untouched' &&
          registry.readPath() == before &&
          registry.readOwner() == null,
      'Foreign root refusal mutated state',
    );
    await sentinel.delete();
    await root.delete();
    cases.add('foreign-root-refusal');

    await temporary((directory) async {
      await File(p.join(directory.path, 'archway.cmd'))
          .writeAsString('@exit /b 0');
      setPath(directory.path, 1);
      await lifecycle.install(oldInstaller.path, expectSuccess: false);
      requirePath(directory.path, 1);
      _require(
        !_exists(root.path) && registry.readOwner() == null,
        'Foreign command refusal created installation',
      );
    });
    cases.add('foreign-command-refusal');

    setPath(raw, 1);
    await install();
    final duplicated = '$raw;$token;$token';
    setPath(duplicated, 1);
    await lifecycle.uninstall(expectSuccess: false);
    requirePath(duplicated, 1);
    _require(await binary.exists(), 'Duplicate-token refusal removed command');
    setPath('$raw;$token', 1);
    await lifecycle.uninstall();
    cases.add('duplicate-token-refusal');

    await temporary((directory) async {
      final sentinel = File(p.join(directory.path, 'foreign.txt'));
      await sentinel.writeAsString('junction target survives');
      await junction(root.path, directory.path);
      final before = registry.readPath();
      try {
        await lifecycle.install(oldInstaller.path, expectSuccess: false);
        _require(
          await sentinel.readAsString() == 'junction target survives' &&
              registry.readPath() == before &&
              registry.readOwner() == null,
          'Root junction refusal mutated state',
        );
      } finally {
        removeWindowsDirectoryEntry(root.path);
      }
    });
    cases.add('root-junction-refusal');

    setPath(raw, 1);
    await install();
    final lock = DeleteDeniedWindowsFileLock(stale.path);
    try {
      await lifecycle.install(
        finalInstaller.path,
        expectSuccess: false,
        expectedExit: 20,
      );
      _require(
        await stale.exists(),
        'Deletion-sharing lock did not retain stale file',
      );
    } finally {
      lock.close();
    }
    await lifecycle.uninstall();
    _require(
      !_exists(stale.path),
      'Uninstall retained locked stale file after release',
    );
    cases.add('locked-stale-file-failure');

    await install();
    _require(await stale.exists(), 'Historical fixture stale file missing');
    await upgrade();
    _require(!_exists(stale.path), 'Historical fixture stale file remains');
    final obsolete = stale.parent;
    if (await obsolete.exists()) await obsolete.delete();
    await temporary((target) async {
      final sentinel = File(p.join(target.path, p.basename(staleFile)));
      await sentinel.writeAsString('foreign historical-name sentinel');
      Future<void> refusalPreservesState() async {
        final path = registry.readPath();
        final owner = registry.readOwner();
        final preserved = {
          for (final name in [
            'bin/windows-x64/archway.exe',
            '.archway-owned-files.txt',
          ])
            name: _hash(File(p.join(root.path, name))),
        };
        for (final uninstall in [true, false]) {
          if (uninstall) {
            await lifecycle.uninstall(expectSuccess: false);
          } else {
            await lifecycle.install(finalInstaller.path, expectSuccess: false);
          }
          final after = registry.readOwner();
          _require(
            registry.readPath() == path &&
                owner != null &&
                after != null &&
                owner.root == after.root &&
                owner.pathToken == after.pathToken,
            'Junction refusal changed registry state',
          );
          for (final entry in preserved.entries) {
            _require(
              _hash(File(p.join(root.path, entry.key))) == entry.value,
              'Junction refusal changed owned bytes',
            );
          }
          _require(
            await sentinel.readAsString() ==
                    'foreign historical-name sentinel' &&
                sameJson(
                  target
                      .listSync(followLinks: false)
                      .map((e) => e.path)
                      .toList(),
                  [sentinel.path],
                ),
            'Junction refusal changed foreign target',
          );
        }
      }

      await junction(obsolete.path, target.path);
      try {
        await refusalPreservesState();
      } finally {
        removeWindowsDirectoryEntry(obsolete.path);
      }
      final unlisted = Directory(p.join(root.path, 'unlisted-雪'));
      final empty = Directory(p.join(unlisted.path, 'empty'));
      await empty.create(recursive: true);
      final link = p.join(unlisted.path, 'junction');
      await junction(link, target.path);
      try {
        await refusalPreservesState();
      } finally {
        removeWindowsDirectoryEntry(link);
      }
      await upgrade();
      await empty.delete();
      await unlisted.delete();
      await lifecycle.uninstall();
      _require(
        await sentinel.readAsString() == 'foreign historical-name sentinel',
        'Final cleanup changed foreign sentinel',
      );
    });
    cases.add('obsolete-directory-junction-uninstall');
    // Receipt labels appear only after their actual scenario has completed.
    final orderedCases = cases.toList();
    // Receipt inventory order is stable; command receipts retain execution order.
    orderedCases.remove('installed-command');
    orderedCases.insert(2, 'installed-command');
    return {'cases': orderedCases, 'installed': installed};
  });
}

Map<String, dynamic> _manifest(Directory root) =>
    (jsonDecode(File(p.join(root.path, 'manifest.json')).readAsStringSync())
            as Map)['files']
        as Map<String, dynamic>;
bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;
String _hash(File file) => sha256.convert(readOrdinaryBytes(file)).toString();
void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
