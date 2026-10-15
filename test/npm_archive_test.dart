import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import 'support/npm_native_fixture.dart';
import 'tar_input_test.dart' show changedHeader;

void main() {
  late Directory root;
  final node = Platform.environment['ARCHWAY_TEST_NODE'] ?? 'node';
  final module = p.absolute('tool/npm/archive.cjs');
  const payload = [97, 98, 99];
  setUp(
    () => root = Directory(
      Directory.systemTemp
          .createTempSync('npm archive café ')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> extract(
    File archive,
    Map<String, Object> pin,
    Map<String, Object> identity,
    String output,
  ) => Process.run(node, [
    '-e',
    "require(process.argv[1]).extractNativeArchive(...JSON.parse(process.argv[2])).catch(e=>{console.error(e.message);process.exitCode=126;});",
    module,
    jsonEncode([archive.path, pin, identity, output]),
  ]);

  test('native TAR/PAX and ZIP extraction retains original bytes and refuses existing output', () async {
    for (final format in ['tar.gz', 'zip']) {
      final f = await npmNativeFixture(root, format);
      final destination = p.join(root.path, format);
      final result = await extract(f.archive, f.pin, f.identity, destination);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, isEmpty);
      final executable =
          'bin/${f.identity['target']}/archway${format == 'zip' ? '.exe' : ''}';
      expect(File(p.join(destination, executable)).readAsBytesSync(), payload);
      expect(
        Directory(destination)
            .listSync(recursive: true)
            .whereType<File>()
            .map(
              (f) =>
                  p.relative(f.path, from: destination).replaceAll('\\', '/'),
            )
            .toSet(),
        {executable, 'manifest.json'},
      );
      final sentinel = File(p.join(destination, 'keep'))
        ..writeAsStringSync('existing');
      final again = await extract(f.archive, f.pin, f.identity, destination);
      expect(again.exitCode, 126);
      expect(again.stderr, contains('already exists'));
      expect(sentinel.readAsStringSync(), 'existing');
    }
  });
  test(
    'matching-byte duplicates and unsafe names fail their own admission guards',
    () async {
      final cases = <(List<(String, List<int>)>, String)>[
        ([('same', payload), ('same', payload)], 'Duplicate archive member'),
        ([('A', payload), ('a', payload)], 'Aliased archive path'),
        ([('e\u0301', payload), ('é', payload)], 'Aliased archive path'),
        (
          [('parent', payload), ('parent/child', payload)],
          'file/directory collision',
        ),
        (
          [('parent/child', payload), ('parent', payload)],
          'file/directory collision',
        ),
        for (final name in [
          '../escape',
          '/escape',
          'a\\b',
          'a//b',
          'CON',
          'a.',
        ])
          (
            [(name, payload)],
            'archive path|fileName|relative path|absolute path',
          ),
      ];
      for (final format in ['tar.gz', 'zip']) {
        for (final (extra, diagnostic) in cases) {
          final f = await npmNativeFixture(root, format, extra: extra);
          final destination = p.join(root.path, 'rejected');
          final result = await extract(
            f.archive,
            f.pin,
            f.identity,
            destination,
          );
          expect(result.exitCode, 126, reason: '$format $extra');
          expect(result.stderr, matches(diagnostic), reason: '$format $extra');
          expect(Directory(destination).existsSync(), isFalse);
          expect(
            root
                .listSync()
                .map((e) => p.basename(e.path))
                .where((n) => n.startsWith('.archway-')),
            isEmpty,
          );
        }
      }
      expect(File(p.join(root.path, 'escape')).existsSync(), isFalse);
    },
  );

  test(
    'pins and complete manifest identities bind admitted archive content',
    () async {
      for (final format in ['tar.gz', 'zip']) {
        for (final issue in [
          'size',
          'archive digest',
          'manifest digest',
          'source',
          'version',
          'target',
          'member hash',
          'member size',
          'member mode',
          'missing member',
          'extra member',
        ]) {
          final f = await npmNativeFixture(
            root,
            format,
            changeManifest: (m) {
              if (issue == 'source') m['source'] = {'commit': 'b' * 40};
              if (issue == 'version') m['version'] = '9.9.9';
              if (issue == 'target') m['target'] = 'macos-arm64';
              if (issue == 'member hash')
                ((m['files'] as Map).values.first as Map)['sha256'] = '0' * 64;
              if (issue == 'member size')
                ((m['files'] as Map).values.first as Map)['size'] = 4;
              if (issue == 'member mode')
                ((m['files'] as Map).values.first as Map)['mode'] = 0x1ed;
            },
            changeMembers: (members) => issue == 'missing member'
                ? members.sublist(1)
                : issue == 'extra member'
                ? [...members, ('extra', payload)]
                : members,
          );
          final pin = {...f.pin};
          if (issue == 'size') pin['size'] = (pin['size'] as int) + 1;
          if (issue == 'archive digest') pin['sha256'] = '0' * 64;
          if (issue == 'manifest digest') pin['manifest_sha256'] = '0' * 64;
          final expected = switch (issue) {
            'size' => 'size differs from pin',
            'archive digest' => 'digest differs from pin',
            'manifest digest' => 'manifest differs from pinned digest',
            'source' || 'version' || 'target' => 'release identity differs',
            'member hash' ||
            'member size' ||
            'member mode' => 'Native inventory differs:',
            _ => 'inventory entry count differs',
          };
          final destination = p.join(root.path, 'rejected');
          final result = await extract(f.archive, pin, f.identity, destination);
          expect(result.exitCode, 126, reason: '$format $issue');
          expect(result.stderr, contains(expected), reason: '$format $issue');
          expect(Directory(destination).existsSync(), isFalse);
        }
      }
    },
  );
  test(
    'ZIP refuses conflicting local size metadata before extraction',
    () async {
      final f = await npmNativeFixture(
        root,
        'zip',
        changeArchive: (bytes) => bytes[18] ^= 1,
      );
      final destination = p.join(root.path, 'rejected');
      final result = await extract(f.archive, f.pin, f.identity, destination);
      expect(result.exitCode, 126);
      expect(result.stderr, contains('ZIP local header differs'));
      expect(Directory(destination).existsSync(), isFalse);
    },
  );
  test('nonordinary entries and declared member bounds are refused before body errors', () async {
    for (final format in ['tar.gz', 'zip']) {
      for (final issue in ['kind', 'size', 'count']) {
        final f = await npmNativeFixture(
          root,
          format,
          extra: issue == 'count'
              ? [for (var i = 0; i < 4096; i++) ('f$i', <int>[])]
              : [('odd', <int>[])],
          extraType: issue == 'kind' ? TypeFlag.dir : TypeFlag.reg,
          zipMode: issue == 'kind' ? 0xa1a4 : 0x81a4,
        );
        var pin = f.pin;
        if (issue == 'size') {
          final original = f.archive.readAsBytesSync();
          List<int> bytes;
          if (format == 'zip') {
            bytes = original;
            // Independent fixture encoding: first central record signature.
            final c = [
              for (var i = 0; i < bytes.length - 4; i++)
                if (bytes[i] == 0x50 &&
                    bytes[i + 1] == 0x4b &&
                    bytes[i + 2] == 1 &&
                    bytes[i + 3] == 2)
                  i,
            ].first;
            for (final offset in [22, c + 24])
              for (var i = 0; i < 4; i++)
                bytes[offset + i] = ((128 * 1024 * 1024 + 1) >> (8 * i)) & 255;
          } else {
            bytes = gzip.encode(
              changedHeader(
                gzip.decode(original),
                (h) => h.setRange(
                  124,
                  136,
                  ascii.encode('1000000001\x00'.padLeft(12, '0')),
                ),
              ),
            );
          }
          f.archive.writeAsBytesSync(bytes);
          pin = {
            ...pin,
            'size': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          };
        }
        final destination = p.join(root.path, 'rejected');
        final result = await extract(f.archive, pin, f.identity, destination);
        expect(result.exitCode, 126, reason: '$format $issue');
        expect(
          result.stderr,
          contains(switch (issue) {
            'kind' => 'ordinary archive file',
            'size' => 'member size bound',
            _ => 'entry bound',
          }),
          reason: '$format $issue',
        );
        expect(Directory(destination).existsSync(), isFalse);
      }
    }
  });
  test(
    'complete inventory refusal precedes observable extraction errors',
    () async {
      final uncreatable = 'x' * 300;
      for (final format in ['tar.gz', 'zip']) {
        final f = await npmNativeFixture(
          root,
          format,
          extra: [
            (uncreatable, [1]),
          ],
          changeManifest: (m) =>
              ((m['files'] as Map)[uncreatable] as Map)['sha256'] = '0' * 64,
        );
        final result = await extract(
          f.archive,
          f.pin,
          f.identity,
          p.join(root.path, 'rejected'),
        );
        expect(result.exitCode, 126);
        expect(
          result.stderr,
          contains('Native inventory differs: $uncreatable'),
        );
        expect(Directory(p.join(root.path, 'rejected')).existsSync(), false);
      }
    },
  );
  test(
    'ZIP output creation failure releases the open member input',
    () async {
      final random = Random(1777);
      final f = await npmNativeFixture(
        root,
        'zip',
        extra: [
          ('x' * 300, List.generate(1024 * 1024, (_) => random.nextInt(256))),
        ],
      );
      final result = await Process.run(node, [
        '-e',
        r"""
const fs=require('node:fs');
(async()=>{
let failed=false;
try{await require(process.argv[1]).extractNativeArchive(...JSON.parse(process.argv[2]));}
catch(e){if(e.code!=='ENAMETOOLONG')throw e;failed=true;}
await new Promise(resolve=>setTimeout(resolve,20));
const leaked=fs.readdirSync('/proc/self/fd').flatMap(name=>{try{return [fs.readlinkSync('/proc/self/fd/'+name)];}catch{return [];}}).filter(name=>name.includes('.archway-archive-'));
console.log(JSON.stringify({failed,leaked}));
})().catch(e=>{console.error(e);process.exitCode=1;});
""",
        module,
        jsonEncode([
          f.archive.path,
          f.pin,
          f.identity,
          p.join(root.path, 'rejected'),
        ]),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final value = jsonDecode(result.stdout as String) as Map;
      expect(value['failed'], true);
      expect(value['leaked'], isEmpty);
    },
    skip: !Platform.isLinux
        ? 'Linux descriptor observation; other hosts retain extraction controls'
        : false,
  );
}
