import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/npm/packed_inventory.dart';
import '../tool/release/archive_input.dart';
import '../tool/release/tar_input.dart';

void main() {
  test(
    'npm portable bin mode is exact and never changes native admission',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('npm-mode-')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      const bin = 'package/bin/archway.cjs';
      const other = 'package/data';
      final hash = sha256.convert([97]).toString();
      final inventory = ArchiveInventory({
        bin: (size: 1, mode: 0x1ed, sha256: hash),
        other: (size: 1, mode: 0x1ed, sha256: hash),
      });
      List<int> bytes(int binMode, int otherMode, {int content = 97}) => [
        ...tarConverter
            .convert(
              TarEntry.data(TarHeader(name: bin, mode: binMode), [content]),
            )
            .take(1024),
        ...tarConverter.convert(
          TarEntry.data(TarHeader(name: other, mode: otherMode), [97]),
        ),
      ];
      Future<void> verify(
        int binMode,
        int otherMode, {
        int content = 97,
      }) async {
        final file = File(p.join(root.path, 'package.tgz'))
          ..writeAsBytesSync(
            gzip.encode(bytes(binMode, otherMode, content: content)),
          );
        await withArchiveInput(
          file,
          (input) => verifyNpmArchiveInput(input, inventory),
        );
      }

      await verify(0x1ed, 0x1ed);
      await verify(0x1a4, 0x1ed);
      for (final mode in [0x180, 0x1b6, 0x1ff, 0x9ed]) {
        await expectLater(verify(mode, 0x1ed), throwsFormatException);
      }
      await expectLater(verify(0x1a4, 0x1a4), throwsFormatException);
      await expectLater(verify(0x1ed, 0x1a4), throwsFormatException);
      await expectLater(
        verify(0x1a4, 0x1ed, content: 98),
        throwsFormatException,
      );
      final tar = File(p.join(root.path, 'native.tar'))
        ..writeAsBytesSync(bytes(0x1a4, 0x1ed));
      await expectLater(
        withArchiveInput(tar, (input) => verifyTarInput(input, inventory)),
        throwsFormatException,
      );
    },
  );

  test(
    'offline npm installation makes a declared 0644 bin executable',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('npm portable bin ')
            .resolveSymbolicLinksSync(),
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final metadata = utf8.encode(
        jsonEncode({
          'name': 'archway-portable-bin-fixture',
          'version': '1.0.0',
          'bin': {'archway-portable-fixture': 'bin/archway.cjs'},
        }),
      );
      final script = utf8.encode(
        '#!/usr/bin/env node\nprocess.stdout.write("portable-bin-ok\\n"); process.exitCode = 37;\n',
      );
      List<int> member(String name, List<int> bytes) => tarConverter.convert(
        TarEntry.data(TarHeader(name: name, mode: 0x1a4), bytes),
      );
      final packageMember = member('package/package.json', metadata);
      final archive = File(p.join(root.path, 'fixture.tgz'))
        ..writeAsBytesSync(
          gzip.encode([
            ...packageMember.take(512 + ((metadata.length + 511) ~/ 512) * 512),
            ...member('package/bin/archway.cjs', script),
          ]),
        );
      final project = Directory(p.join(root.path, 'project'))..createSync();
      final environment = Map<String, String>.from(Platform.environment)
        ..removeWhere(
          (key, _) => [
            'node_options',
            'node_path',
            'node_auth_token',
            'npm_token',
          ].contains(key.toLowerCase()),
        );
      Future<ProcessResult> npm(List<String> args) => Process.run(
        'npm',
        [
          ...args,
          '--offline',
          '--no-update-notifier',
          '--ignore-scripts',
          '--no-audit',
          '--no-fund',
        ],
        workingDirectory: project.path,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
      );
      final installed = await npm(['install', archive.path]);
      expect(
        installed.exitCode,
        0,
        reason: '${installed.stdout}\n${installed.stderr}',
      );
      final executed = await Process.run(
        'npm',
        [
          'exec',
          '--offline',
          '--no-update-notifier',
          '--',
          'archway-portable-fixture',
        ],
        workingDirectory: project.path,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
      );
      expect(
        executed.exitCode,
        37,
        reason: '${executed.stdout}\n${executed.stderr}',
      );
      expect(executed.stdout, 'portable-bin-ok\n');
      final installedBin = File(
        p.join(
          project.path,
          'node_modules',
          'archway-portable-bin-fixture',
          'bin',
          'archway.cjs',
        ),
      );
      expect(installedBin.readAsBytesSync(), script);
      if (!Platform.isWindows)
        expect(installedBin.statSync().mode & 0x40, 0x40);
    },
  );
}
