// Portable build-input checks, not native Windows/Inno lifecycle acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/installers/windows/casefold.dart';

String fixtureMemberPath(String root, String member, {p.Context? paths}) =>
    (paths ?? p.context).joinAll([root, ...member.split('/')]);

Future<void> prepareWindowsInstaller(
  Directory payload,
  Directory output,
) async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'tool/installers/windows/prepare.dart',
    payload.path,
    output.path,
  ]);
  if (result.exitCode != 0) throw FormatException('${result.stderr}');
}

void main() {
  test(
    'fixture member paths use native separators for nested inventory keys',
    () {
      expect(
        fixtureMemberPath(
          r'C:\payload café',
          'bin/windows-x64/archway.exe',
          paths: p.Context(style: p.Style.windows),
        ),
        r'C:\payload café\bin\windows-x64\archway.exe',
      );
      expect(
        fixtureMemberPath(
          '/payload café',
          'bin/windows-x64/archway.exe',
          paths: p.Context(style: p.Style.posix),
        ),
        '/payload café/bin/windows-x64/archway.exe',
      );
    },
  );
  test('pinned full-fold expands and preserves compatibility scalars', () {
    expect(installerCaseFold('Straße ﬀ İ ς'), 'strasse ff i\u0307 σ');
    expect(installerCaseFold('Ꭰꭰ'), 'ᎠᎠ');
    // Unicode 16 additions retain their Unicode 15.1 identity.
    expect(installerCaseFold('\u{1c89}'), '\u{1c89}');
  });
  late Directory root, payload, output;
  setUp(() {
    root = Directory(
      Directory.systemTemp.createTempSync('inno-').resolveSymbolicLinksSync(),
    );
    payload = Directory(p.join(root.path, 'payload café'))..createSync();
    output = Directory(p.join(root.path, 'prepared'));
  });
  tearDown(() => root.deleteSync(recursive: true));
  void fixture([
    List<String> names = const [
      'LICENSE',
      'bin/windows-x64/archway.exe',
      'example..txt',
    ],
  ]) {
    final files = <String, Object?>{};
    for (final name in names) {
      final file = File(fixtureMemberPath(payload.path, name));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fixture');
      files[name] = {
        'sha256': sha256.convert(utf8.encode('fixture')).toString(),
        'size': 7,
        'mode': 493,
      };
    }
    File(
      p.join(payload.path, 'manifest.json'),
    ).writeAsStringSync(jsonEncode({'target': 'windows-x64', 'files': files}));
  }

  test('emits complete ordered inventory and exact Inno inputs without mutating payload', () async {
    fixture();
    final before = {
      for (final file in payload.listSync(recursive: true).whereType<File>())
        file.path: file.readAsBytesSync(),
    };
    await prepareWindowsInstaller(payload, output);
    final newline = Platform.isWindows ? '\r\n' : '\n';
    final names = Platform.isWindows
        ? [
            'bin/windows-x64/archway.exe',
            'example..txt',
            'LICENSE',
            'manifest.json',
          ]
        : [
            'LICENSE',
            'bin/windows-x64/archway.exe',
            'example..txt',
            'manifest.json',
          ];
    expect(
      File(p.join(output.path, 'owned-files.txt')).readAsStringSync(),
      names
          .map(
            (name) =>
                '${sha256.convert(before[fixtureMemberPath(payload.path, name)]!)}\t${name.replaceAll('/', r'\')}$newline',
          )
          .join(),
    );
    expect(
      File(p.join(output.path, 'payload.iss')).readAsStringSync(),
      names.map((name) {
        final directory = name.contains('/')
            ? r'{app}\bin\windows-x64'
            : '{app}';
        return 'Source: "${fixtureMemberPath(payload.path, name)}"; DestDir: "$directory"; Flags: ignoreversion$newline';
      }).join(),
    );
    for (final name in ['archway.iss', 'lifecycle.iss']) {
      expect(
        File(p.join(output.path, name)).readAsBytesSync(),
        File('tool/installers/windows/$name').readAsBytesSync(),
      );
    }
    expect({
      for (final file in payload.listSync(recursive: true).whereType<File>())
        file.path: file.readAsBytesSync(),
    }, before);
  });
  test(
    'escapes source braces and quotes and preserves component ordering',
    () async {
      if (!Platform.isWindows) {
        payload = payload.renameSync(p.join(root.path, 'payload {" café'));
      } else {
        payload = payload.renameSync(p.join(root.path, 'payload { café'));
      }
      fixture(['bin/windows-x64/archway.exe', 'a.txt', 'a/file', 'Z']);
      await prepareWindowsInstaller(payload, output);
      final contents = File(p.join(output.path, 'payload.iss'))
          .readAsStringSync();
      expect(
        contents,
        contains(payload.path.replaceAll('"', '""').replaceAll('{', '{{')),
      );
      final order = File(p.join(output.path, 'owned-files.txt'))
          .readAsLinesSync()
          .map((line) => line.split('\t').last)
          .toList();
      expect(
        order,
        Platform.isWindows
            ? [
                r'a\file',
                'a.txt',
                r'bin\windows-x64\archway.exe',
                'manifest.json',
                'Z',
              ]
            : [
                'Z',
                r'a\file',
                'a.txt',
                r'bin\windows-x64\archway.exe',
                'manifest.json',
              ],
      );
    },
  );
  test(
    'refuses existing, nested and aliased destinations before changes',
    () async {
      fixture();
      output.createSync();
      final sentinel = File(p.join(output.path, 'sentinel'))
        ..writeAsStringSync('keep');
      await expectLater(
        prepareWindowsInstaller(payload, output),
        throwsFormatException,
      );
      expect(sentinel.readAsStringSync(), 'keep');
      await expectLater(
        prepareWindowsInstaller(
          payload,
          Directory(p.join(payload.path, 'new')),
        ),
        throwsFormatException,
      );
      expect(Directory(p.join(payload.path, 'new')).existsSync(), isFalse);
      {
        final alias = Link(p.join(root.path, 'alias'))
          ..createSync(payload.path);
        await expectLater(
          prepareWindowsInstaller(
            payload,
            Directory(p.join(alias.path, 'new')),
          ),
          throwsFormatException,
        );
        final outside = Directory(p.join(root.path, 'outside'))..createSync();
        final external = Link(p.join(root.path, 'external'))
          ..createSync(outside.path);
        await expectLater(
          prepareWindowsInstaller(
            payload,
            Directory(p.join(external.path, 'new')),
          ),
          throwsFormatException,
        );
        expect(outside.listSync(), isEmpty);
      }
    },
  );
  test('creates absent canonical output parents', () async {
    fixture();
    output = Directory(p.join(root.path, 'new', 'parents', 'out'));
    await prepareWindowsInstaller(payload, output);
    expect(File(p.join(output.path, 'payload.iss')).existsSync(), isTrue);
  });
  for (final member in [
    'UNINSdata/file',
    '.ARCHWAY-state/file',
    'bad{brace}',
    'bad}brace',
    'CON.txt',
    'trailing.',
    'trailing ',
    'bad*name',
  ]) {
    test(
      'refuses installer member $member before output',
      () async {
        // POSIX can create the invalid Windows names used by these controls.
        fixture(['bin/windows-x64/archway.exe', member]);
        await expectLater(
          prepareWindowsInstaller(payload, output),
          throwsFormatException,
        );
        expect(output.existsSync(), isFalse);
      },
      skip:
          Platform.isWindows &&
              {'CON.txt', 'trailing.', 'trailing ', 'bad*name'}.contains(member)
          ? 'POSIX-only invalid Windows filename fixture.'
          : false,
    );
  }
  for (final variant in [
    'target',
    'missing command',
    'bytes',
    'extra',
    'missing',
    'mode missing',
    'entry extra',
    'empty directory',
    'case directory',
  ]) {
    test('refuses $variant before output', () async {
      fixture(
        variant == 'missing command'
            ? ['LICENSE']
            : variant == 'case directory'
            ? ['bin/windows-x64/archway.exe', 'Assets/a', 'assets/b']
            : ['LICENSE', 'bin/windows-x64/archway.exe'],
      );
      final file = File(p.join(payload.path, 'manifest.json'));
      final manifest =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (variant == 'target') manifest['target'] = 'linux-x64';
      if (variant == 'mode missing')
        (manifest['files']['LICENSE'] as Map).remove('mode');
      if (variant == 'entry extra')
        manifest['files']['LICENSE']['other'] = true;
      file.writeAsStringSync(jsonEncode(manifest));
      if (variant == 'bytes')
        File(p.join(payload.path, 'LICENSE')).writeAsStringSync('changed');
      if (variant == 'extra')
        File(p.join(payload.path, 'extra')).writeAsStringSync('extra');
      if (variant == 'missing')
        File(p.join(payload.path, 'LICENSE')).deleteSync();
      if (variant == 'empty directory')
        Directory(p.join(payload.path, 'empty')).createSync();
      await expectLater(
        prepareWindowsInstaller(payload, output),
        throwsFormatException,
      );
      expect(output.existsSync(), isFalse);
    });
  }
  test('refuses linked input files and payload root', () async {
    fixture();
    final original = File(p.join(payload.path, 'LICENSE'));
    final elsewhere = original.renameSync(p.join(root.path, 'license'));
    Link(original.path).createSync(elsewhere.path);
    await expectLater(
      prepareWindowsInstaller(payload, output),
      throwsFormatException,
    );
    expect(output.existsSync(), isFalse);
    Link(original.path).deleteSync();
    elsewhere.renameSync(original.path);
    final alias = Link(p.join(root.path, 'alias'))..createSync(payload.path);
    await expectLater(
      prepareWindowsInstaller(Directory(alias.path), output),
      throwsFormatException,
    );
    expect(output.existsSync(), isFalse);
  });
  test('preserves Python full-fold collision refusal for files and directory prefixes', () async {
    fixture(['bin/windows-x64/archway.exe', 'Straße/a', 'STRASSE/b']);
    await expectLater(
      prepareWindowsInstaller(payload, output),
      throwsFormatException,
    );
    expect(output.existsSync(), isFalse);
  });
}
