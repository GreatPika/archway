import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import '../tool/ci/native_windows_installer_probe.dart';

void main() {
  test(
    'native admission never creates evidence on unsupported hosts',
    () async {
      if (Platform.isWindows) return;
      final temp = await Directory.systemTemp.createTemp('windows admission ');
      addTearDown(() => temp.delete(recursive: true));
      final output = Directory('${temp.path}/missing/output');
      await expectLater(
        runWindowsInstallerProbe(
          version: '0.1.0',
          builderDart: File(Platform.resolvedExecutable),
          repository: temp,
          bundle: temp,
          output: output,
          disposableAccount: true,
          inspect: (_, _) async => {},
        ),
        throwsUnsupportedError,
      );
      expect(await Directory('${temp.path}/missing').exists(), isFalse);
    },
  );
  test(
    'native installer admits slash-spelled relative report output before builder checks',
    () async {
      final temp = Directory(
        await (await Directory.current.createTemp('windows report '))
            .resolveSymbolicLinks(),
      );
      addTearDown(() => temp.delete(recursive: true));
      final bundle = await Directory(p.join(temp.path, 'bundle')).create();
      final report = File(
        '${p.basename(temp.path)}/build/release-native/report.json',
      ).absolute;
      await report.parent.create(recursive: true);
      final output = Directory(p.join(report.parent.path, 'installer'));
      await expectLater(
        runWindowsInstallerProbe(
          version: '0.1.0',
          builderDart: File(p.join(temp.path, 'absent-dart.exe')),
          repository: temp,
          bundle: bundle,
          output: output,
          disposableAccount: true,
          inspect: (_, _) async => throw StateError('Unexpected inspection'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'builder admission',
            'Explicit absolute builder Dart executable required',
          ),
        ),
      );
      expect(await output.exists(), isFalse);
      expect(await report.exists(), isFalse);
      expect(await report.parent.list().toList(), isEmpty);
      expect(await bundle.list().toList(), isEmpty);
    },
    skip: !Platform.isWindows
        ? 'Requires genuine Windows path admission'
        : false,
  );
  test('native output refusals preserve existing bytes and never create nested output', () async {
    final temp = Directory(
      await (await Directory.systemTemp.createTemp('windows output '))
          .resolveSymbolicLinks(),
    );
    addTearDown(() => temp.delete(recursive: true));
    final bundle = await Directory(p.join(temp.path, 'bundle')).create();
    final existing = await Directory(p.join(temp.path, 'existing')).create();
    final sentinel = await File(p.join(existing.path, 'sentinel'))
        .writeAsBytes([0, 255, 10]);
    final nested = Directory(p.join(bundle.path, 'new', 'child'));
    final alias = await Link(p.join(temp.path, 'alias')).create(existing.path);
    final aliased = Directory(p.join(alias.path, 'new', 'child'));
    final dotted = Directory(p.join(temp.path, '.', 'new', 'child'));
    for (final output in [existing, nested, aliased, dotted]) {
      final operation = Platform.isWindows
          ? runWindowsInstallerProbe(
              version: '0.1.0',
              builderDart: File(Platform.resolvedExecutable),
              repository: temp,
              bundle: bundle,
              output: output,
              disposableAccount: true,
              inspect: (_, _) async => {},
            )
          : validateWindowsInstallerOutput(bundle, output);
      await expectLater(operation, throwsFormatException);
      expect(await sentinel.readAsBytes(), [0, 255, 10]);
      expect(existing.listSync().map((e) => e.path), [sentinel.path]);
      expect(await Directory(p.join(bundle.path, 'new')).exists(), isFalse);
      expect(await Directory(p.join(temp.path, 'new')).exists(), isFalse);
      expect(await alias.target(), existing.path);
    }
  });

  test(
    'old generation adds hashed stale control without changing any final bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp('old bundle ');
      addTearDown(() => temp.delete(recursive: true));
      final bundle = await Directory('${temp.path}/bundle').create();
      await File('${bundle.path}/payload').writeAsBytes([0, 255, 10]);
      await File('${bundle.path}/manifest.json').writeAsString(
        jsonEncode({
          'version': '0.1.0',
          'files': {
            'payload': {'size': 3},
          },
        }),
      );
      final before = {
        for (final entry in bundle.listSync())
          entry.path: File(entry.path).readAsBytesSync(),
      };
      final old = Directory('${temp.path}/old');
      await prepareWindowsInstallerOldFixture(bundle, old);
      final manifest = jsonDecode(
        File('${old.path}/manifest.json').readAsStringSync(),
      ) as Map;
      final stale = File('${old.path}/$windowsInstallerStaleFile');
      expect(manifest['version'], '0.0.0');
      expect((manifest['files'] as Map).keys.toSet(), {
        'payload',
        windowsInstallerStaleFile,
      });
      expect((manifest['files'] as Map)[windowsInstallerStaleFile], {
        'mode': 420,
        'size': stale.lengthSync(),
        'sha256': sha256.convert(stale.readAsBytesSync()).toString(),
      });
      expect({
        for (final entry in bundle.listSync())
          entry.path: File(entry.path).readAsBytesSync(),
      }, before);
      await Directory('${bundle.path}/obsolete').create();
      final refused = Directory('${temp.path}/refused');
      await expectLater(
        prepareWindowsInstallerOldFixture(bundle, refused),
        throwsStateError,
      );
      expect(await refused.exists(), isFalse);
    },
  );

  test(
    'compiler identity requires unique supported authoritative engine line',
    () {
      expect(
        windowsInstallerCompilerVersion(
          utf8.encode(
            'Inno Setup 6 Command-Line Compiler\r\nCompiler engine version: Inno Setup 6.3.3\r\n',
          ),
        ),
        '6.3.3',
      );
      for (final invalid in [
        '0.0.0.0',
        'Inno Setup 6 Command-Line Compiler',
        'Compiler engine version: Inno Setup 6.2.9',
        'Compiler engine version: Inno Setup 6.7.1 beta',
        'Compiler engine version: Inno Setup 6.3.3\nCompiler engine version: Inno Setup 6.3.3',
      ]) {
        expect(
          () => windowsInstallerCompilerVersion(utf8.encode(invalid)),
          throwsFormatException,
        );
      }
    },
  );
}
