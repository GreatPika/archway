// Execute the exact final portable archive on its real host; no publication.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/installation_artifact.dart';
import '../release/installation_identity.dart';
import '../release/native_archive.dart';
import '../validation/json_values.dart';
import 'installed_command_recorder.dart';
import 'native_acceptance.dart';
import 'native_acceptance_runner.dart';
import 'native_installed_commands.dart';
import 'native_installed_inspection.dart';
import 'native_linux_installer_probe.dart';
import 'native_macos_installer_probe.dart';
import 'native_release_host.dart';
import 'native_windows_installer_probe.dart';
import 'release_execution_receipts.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < arguments.length; i++) {
      final name = arguments[i];
      if (const ['--ci-host', '--installer-checks'].contains(name)) {
        if (!flags.add(name)) throw FormatException('Duplicate option: $name');
      } else if (const [
        '--release-directory',
        '--expected-commit',
        '--target',
        '--report',
        '--acceptance-fixtures',
      ].contains(name)) {
        if (options.containsKey(name) ||
            i + 1 == arguments.length ||
            arguments[i + 1].startsWith('--')) {
          throw FormatException('Missing or duplicate value: $name');
        }
        options[name] = arguments[++i];
      } else {
        throw FormatException('Unknown option: $name');
      }
    }
    for (final name in [
      '--release-directory',
      '--expected-commit',
      '--target',
      '--report',
    ]) {
      if (options[name]?.isNotEmpty != true)
        throw FormatException('Required option: $name');
    }
    await probeNativeRelease(
      release: Directory(options['--release-directory']!).absolute,
      expectedCommit: options['--expected-commit']!,
      target: options['--target']!,
      report: File(options['--report']!).absolute,
      fixtureFile: options['--acceptance-fixtures'] == null
          ? null
          : File(options['--acceptance-fixtures']!).absolute,
      ciHost: flags.contains('--ci-host'),
      installerChecks: flags.contains('--installer-checks'),
    );
  } catch (error) {
    stderr.writeln('Native release smoke failed: $error');
    exitCode = 1;
  }
}

Future<void> probeNativeRelease({
  required Directory release,
  required String expectedCommit,
  required String target,
  required File report,
  File? fixtureFile,
  bool ciHost = false,
  bool installerChecks = false,
}) async {
  if (await FileSystemEntity.type(report.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Report already exists');
  }
  if (installerChecks && (!ciHost || fixtureFile == null)) {
    throw ArgumentError(
      'Installer checks require verified CI host and prepared fixtures',
    );
  }
  final repository = Directory(await Directory.current.resolveSymbolicLinks());
  final identity = await sourceIdentity(repository);
  if (identity['commit'] != expectedCommit)
    throw StateError('Source checkout differs from expected commit');
  final host = await nativeReleaseHost(target, ciHost: ciHost);
  final node = await nativeReleaseNode(target);
  final windows = target == 'windows-x64';
  final filename = 'archway-0.1.0-$target${windows ? '.zip' : '.tar.gz'}';
  final archive = File(p.join(release.path, filename));
  final sums = <String, String>{};
  final checksumBytes = readOrdinaryBytes(
    File(p.join(release.path, 'SHA256SUMS')),
    limit: maxArchiveJsonBytes,
  );
  for (final line in const LineSplitter().convert(utf8.decode(checksumBytes))) {
    final match = RegExp(r'^([0-9a-f]{64})  ([^/\\]+)$').firstMatch(line);
    if (match == null || sums.containsKey(match[2])) {
      throw const FormatException('Invalid SHA256SUMS inventory');
    }
    sums[match[2]!] = match[1]!;
  }
  ArchiveInventory({
    for (final name in sums.keys)
      name: (size: 0, mode: 420, sha256: sums[name]!),
  });
  await withArchiveInput(archive, (snapshot) async {
    if (sums[filename] != snapshot.sha256)
      throw StateError('SHA256SUMS mismatch');
    final verified = await verifyNativeArchive(
      snapshot.file,
      format: windows ? NativeArchiveFormat.zip : NativeArchiveFormat.tarGzip,
    );
    if (!sameJson(verified.manifest['source'], identity) ||
        verified.manifest['target'] != target) {
      throw StateError('Final native manifest source/target mismatch');
    }
    final base = Directory(
      await (await Directory.systemTemp.createTemp('archway release '))
          .resolveSymbolicLinks(),
    );
    Object? primary;
    StackTrace? primaryStack;
    Map<String, Object?>? proof;
    try {
      await report.parent.create(recursive: true);
      final commandLogs = Directory(p.join(report.parent.path, 'portable'));
      if (await FileSystemEntity.type(commandLogs.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Portable evidence already exists');
      }
      await commandLogs.create();
      final recorder = InstalledCommandRecorder(output: commandLogs);
      final extracted = Directory(p.join(base.path, 'extracted installation'));
      // Extract only the verified immutable snapshot, never reopen source bytes.
      final extractArchive = await snapshot.file.copy(
        p.join(base.path, windows ? 'archive.zip' : 'archive.tar.gz'),
      );
      if (windows) {
        await recorder.capture(
          [
            _powerShell(),
            '-NoProfile',
            '-Command',
            r'$ErrorActionPreference="Stop"; Expand-Archive -LiteralPath $env:ARCHWAY_SMOKE_ARCHIVE -DestinationPath $env:ARCHWAY_SMOKE_OUTPUT',
          ],
          environment: {
            ...Platform.environment,
            'ARCHWAY_SMOKE_ARCHIVE': extractArchive.path,
            'ARCHWAY_SMOKE_OUTPUT': extracted.path,
          },
          timeout: const Duration(seconds: 60),
        );
      } else {
        await extracted.create();
        await recorder.capture([
          'tar',
          '-xzf',
          extractArchive.path,
          '-C',
          extracted.path,
        ], timeout: const Duration(seconds: 60));
      }
      var bundle = extracted;
      Future<void> verifyInstallation() => verifyInstallationDirectory(
        bundle,
        verified.completeArchiveInventory,
        compareModes: !windows,
      );
      await verifyInstallation();
      bundle = await extracted.rename(
        p.join(base.path, 'relocated café installation'),
      );
      if (await FileSystemEntity.type(extracted.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Original installation survived relocation');
      }
      await verifyInstallation();
      final binary = File(
        p.join(bundle.path, 'bin', target, windows ? 'archway.exe' : 'archway'),
      );
      final installed = await runInstalledCommands(
        binary,
        bundle,
        base,
        node.executable,
        recorder,
      );
      Map<String, Object?>? installer;
      if (installerChecks) {
        final fixtures = readFixtures(fixtureFile!);
        final builderDart = File(
          p.join(
            fixtures.paths['dart_sdk']!,
            'bin',
            windows ? 'dart.exe' : 'dart',
          ),
        );
        final output = Directory(p.join(report.parent.path, 'installer'));
        Future<Map<String, Object?>> inspect(
          File command,
          Directory root,
        ) async {
          final projectBase = Directory(
            p.join(base.path, 'installer commands'),
          );
          await projectBase.create();
          return inspectInstalledCommands(
            command,
            root,
            target: target,
            repository: repository,
            base: projectBase,
            node: node.executable,
            fixtureFile: fixtureFile,
            output: output,
          );
        }

        installer = switch (target) {
          'linux-x64' => await runLinuxInstallerProbe(
            builderDart: builderDart,
            repository: repository,
            bundle: bundle,
            output: output,
            expectedCommit: expectedCommit,
            privilege: ['sudo', '-n'],
            inspect: inspect,
          ),
          'macos-arm64' => await runMacosInstaller(
            repository: repository,
            builderDart: builderDart,
            bundle: bundle,
            output: output,
            inspect: inspect,
          ),
          'windows-x64' => await runWindowsInstallerProbe(
            builderDart: builderDart,
            repository: repository,
            bundle: bundle,
            output: output,
            disposableAccount: ciHost,
            inspect: inspect,
          ),
          _ => throw StateError('Unsupported target'),
        };
        installer.addAll({
          'scope': 'Native build and command-line lifecycle; GUI/trust/fresh desktop terminal pending',
          'bundle_manifest_sha256': verified.manifestSha256,
        });
      }
      Map<String, Object?>? acceptance;
      if (fixtureFile != null) {
        final harness = Directory.fromUri(Platform.script.resolve('../../'));
        if (ciHost && !sameJson(await sourceIdentity(harness), identity)) {
          throw StateError(
            'Acceptance test checkout differs from archive source',
          );
        }
        acceptance = await runAcceptance(
          harness,
          binary.path,
          node.executable.path,
          fixtureFile,
          Directory(p.join(report.parent.path, 'acceptance')),
          verifyInstallation,
          target: target,
        );
      }
      await verifyInstallation();
      await withArchiveInput(
        archive,
        (_) async {},
        expected: (size: snapshot.size, sha256: snapshot.sha256),
      );
      if (!sameJson(await sourceIdentity(repository), identity))
        throw StateError('Source changed during host checks');
      proof = {
        'scope': 'Final native archive extraction, policy and bounded TypeScript checks',
        'source': identity,
        'source_root': repository.path,
        'target': target,
        'host': host,
        'ci_host_verified': ciHost,
        'archive': filename,
        'archive_sha256': snapshot.sha256,
        'node': node.identity,
        'native_commands': installed['native_commands'],
        'typescript': installed['typescript'],
        'acceptance': acceptance,
        'installer': installer,
        'relocation': {
          'extracted': extracted.path,
          'executed': bundle.path,
          'original_removed': true,
        },
      };
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
    } finally {
      try {
        await base.delete(recursive: true);
      } catch (error, stack) {
        primary ??= error;
        primaryStack ??= stack;
      }
    }
    if (primary != null) Error.throwWithStackTrace(primary, primaryStack!);
    await report.create(exclusive: true);
    await report.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(proof)}\n',
      flush: true,
    );
  });
}

// Windows capture starts an explicit executable rather than performing PATH
// lookup. Resolve the host prerequisite before handing it to that boundary.
String _powerShell() {
  final path = Platform.environment.entries
      .where((entry) => entry.key.toUpperCase() == 'PATH')
      .map((entry) => entry.value)
      .firstOrNull;
  for (final directory in (path ?? '').split(';')) {
    if (directory.isEmpty) continue;
    final candidate = File(p.join(directory, 'pwsh.exe'));
    if (candidate.existsSync()) return candidate.resolveSymbolicLinksSync();
  }
  throw StateError('Prerequisite failure: native PowerShell is unavailable.');
}
