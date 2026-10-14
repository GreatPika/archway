import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:tar/tar.dart';

import '../tool/release/installation_identity.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final fault in ['checksum', 'source', 'target', 'extraction'])
    test(
      'native release $fault boundary keeps evidence before final report admission',
      () async {
        final temporary = Directory(
          await (await Directory.systemTemp.createTemp('native release '))
              .resolveSymbolicLinks(),
        );
        addTearDown(() => temporary.delete(recursive: true));
        final source = Directory(p.join(temporary.path, 'source'))
          ..createSync();
        for (final name in [
          'pubspec.lock',
          'assets/typescript/package-lock.json',
        ]) {
          final file = File(p.join(source.path, name));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync('{}\n');
        }
        String git(List<String> arguments) {
          final result = Process.runSync(
            'git',
            arguments,
            workingDirectory: source.path,
          );
          expect(result.exitCode, 0, reason: '${result.stderr}');
          return '${result.stdout}'.trim();
        }

        git(['init', '-q', '--template=']);
        git(['add', '.']);
        git([
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          '-c',
          'commit.gpgSign=false',
          'commit',
          '-qm',
          'Synthetic release source',
        ]);
        final target = switch (Abi.current()) {
          Abi.linuxX64 => 'linux-x64',
          Abi.macosArm64 => 'macos-arm64',
          Abi.windowsX64 => 'windows-x64',
          _ => throw UnsupportedError('Native release host'),
        };
        final release = Directory(p.join(temporary.path, 'release'))
          ..createSync();
        final name =
            'archway-0.1.0-$target${Platform.isWindows ? '.zip' : '.tar.gz'}';
        final payload = utf8.encode('Never execute this payload');
        final manifest = utf8.encode(
          jsonEncode({
            'target': fault == 'target' ? 'unsupported' : target,
            'source': fault == 'source'
                ? {'commit': 'incorrect'}
                : await sourceIdentity(source),
            'files': {
              'bin/core': {
                'size': payload.length,
                'mode': 493,
                'sha256': sha256.convert(payload).toString(),
              },
            },
          }),
        );
        final List<int> bytes;
        if (Platform.isWindows) {
          final zip = archive.Archive()
            ..addFile(
              archive.ArchiveFile.bytes('bin/core', payload)..mode = 0x81ed,
            )
            ..addFile(
              archive.ArchiveFile.bytes('manifest.json', manifest)
                ..mode = 0x81a4,
            );
          bytes = archive.ZipEncoder().encode(zip);
        } else {
          bytes = gzip.encode([
            for (final entry in [
              TarEntry.data(TarHeader(name: 'bin/core', mode: 493), payload),
              TarEntry.data(
                TarHeader(name: 'manifest.json', mode: 420),
                manifest,
              ),
            ])
              ...tarConverter
                  .convert(entry)
                  .take(512 + ((entry.header.size + 511) ~/ 512) * 512),
            ...List.filled(1024, 0),
          ]);
        }
        File(p.join(release.path, name)).writeAsBytesSync(bytes);
        final digest = fault == 'checksum'
            ? '0' * 64
            : sha256.convert(bytes).toString();
        File(p.join(release.path, 'SHA256SUMS'))
            .writeAsStringSync('$digest  $name\n');
        final report = File(
          p.join(temporary.path, 'must-not-exist/report.json'),
        );
        final result = await Process.run(Platform.resolvedExecutable, [
          p.absolute('tool/ci/release_native_smoke.dart'),
          '--release-directory',
          release.path,
          '--expected-commit',
          git(['rev-parse', 'HEAD']),
          '--target',
          target,
          '--report',
          report.path,
        ], workingDirectory: source.path);
        expect(result.exitCode, isNot(0));
        if (fault == 'extraction') {
          final receipt = jsonDecode(
            await File(
              p.join(report.parent.path, 'portable', 'installed-0.json'),
            ).readAsString(),
          ) as Map;
          expect(receipt['exit_code'], 0, reason: '${result.stderr}');
          expect(receipt['timed_out'], false);
          expect(report.existsSync(), isFalse);
          return;
        }
        expect(
          result.stderr,
          contains(
            fault == 'checksum'
                ? 'SHA256SUMS mismatch'
                : 'Final native manifest source/target mismatch',
          ),
        );
        expect(report.parent.existsSync(), isFalse);
      },
    );
}
