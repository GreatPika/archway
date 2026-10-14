import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_native_admission.dart';
import 'finalizer_receipt_fixtures.dart';

void main() {
  test(
    'archive bytes must match coherent receipt and expected digest claims',
    () async {
      final f = FinalizerReceiptFixture('linux-x64');
      addTearDown(f.close);
      f.proof['archive_sha256'] = '0' * 64;
      f.save();
      await expectLater(
        admitNativeReceipt(
          version: '0.1.0',
          artifact: f.root,
          report: f.nativeEvidence.report,
          archive: f.archiveFile,
          target: 'linux-x64',
          archiveSha256: '0' * 64,
          source: f.nativeEvidence.source,
          repository: f.sourceEvidence.repo,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Native archive checksum differs',
          ),
        ),
      );
    },
  );
  final mutations = <String, void Function(FinalizerReceiptFixture)>{
    'unverified host': (f) => f.proof['ci_host_verified'] = false,
    'wrong archive identity': (f) => f.proof['archive_sha256'] = '0' * 64,
    'wrong target': (f) => f.proof['target'] = 'macos-arm64',
    'missing public command': (f) =>
        (f.proof['native_commands'] as List).removeLast(),
    'wrong TypeScript exit': (f) =>
        (f.proof['typescript'] as List)[1]['exit'] = 0,
    'native original bytes': (f) =>
        File(p.join(f.nativeEvidence.directory.path, 'plan_query.stdout.log'))
            .writeAsStringSync('changed'),
    'source original bytes': (f) =>
        File(p.join(f.nativeEvidence.directory.path, 'source-tests.stdout.log'))
            .writeAsStringSync('changed'),
    'installer original bytes': (f) => File(
      p.join(f.root.path, 'installer', 'archway-0.1.0-linux-x64-unsigned.deb'),
    ).writeAsStringSync('changed'),
  };
  for (final mutation in mutations.entries) {
    test('aggregate native admission requires ${mutation.key}', () async {
      final f = FinalizerReceiptFixture('linux-x64');
      addTearDown(f.close);
      final digest = f.proof['archive_sha256'] as String;
      mutation.value(f);
      f.save();
      await expectLater(
        admitNativeReceipt(
          version: '0.1.0',
          artifact: f.root,
          report: f.nativeEvidence.report,
          archive: f.archiveFile,
          target: 'linux-x64',
          archiveSha256: digest,
          source: f.nativeEvidence.source,
          repository: f.sourceEvidence.repo,
        ),
        throwsFormatException,
      );
    });
  }
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    test(
      '$target rejects a coherently hashed stale manifest version',
      () async {
        final f = FinalizerReceiptFixture(
          target,
          version: '3.4.5',
          manifestVersion: '0.1.0',
        );
        addTearDown(f.close);
        await expectLater(
          admitNativeReceipt(
            artifact: f.root,
            report: f.nativeEvidence.report,
            archive: f.archiveFile,
            target: target,
            version: '3.4.5',
            archiveSha256: f.proof['archive_sha256'] as String,
            source: f.nativeEvidence.source,
            repository: f.sourceEvidence.repo,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Native archive version differs from source',
            ),
          ),
        );
      },
    );
    for (final version in ['0.1.0', '3.4.5']) {
      test(
        'admits coherent original $target $version source, archive and installer evidence',
        () async {
          final f = FinalizerReceiptFixture(target, version: version);
          addTearDown(f.close);
          final accepted = await admitNativeReceipt(
            version: version,
            artifact: f.root,
            report: f.nativeEvidence.report,
            archive: f.archiveFile,
            target: target,
            archiveSha256: f.proof['archive_sha256'] as String,
            source: f.nativeEvidence.source,
            repository: f.sourceEvidence.repo,
          );
          await expectLater(
            admitNativeReceipt(
              artifact: f.root,
              report: f.nativeEvidence.report,
              archive: f.archiveFile,
              target: target,
              version: '8.7.6',
              archiveSha256: f.proof['archive_sha256'] as String,
              source: f.nativeEvidence.source,
              repository: f.sourceEvidence.repo,
            ),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                'Native receipt does not establish required archive checks',
              ),
            ),
          );
          expect(accepted.report, f.nativeEvidence.report);
          expect(
            accepted.installer.readAsStringSync(),
            'SYNTHETIC INSTALLER FIXTURE ONLY',
          );
          expect(
            accepted.installerSha256,
            FinalizerReceiptFixture.hash(accepted.installer.readAsBytesSync()),
          );
        },
      );
    }
  }
}
