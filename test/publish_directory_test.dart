import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/publish_directory.dart';
import 'support/process_lifecycle.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('publication-test-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'cold collision preserves empty directories, files and dangling aliases',
    () {
      for (final kind in ['empty', 'nonempty', 'file', 'alias']) {
        final parent = Directory(p.join(root.path, '$kind'))..createSync();
        final stage = Directory(p.join(parent.path, 'stage'))..createSync();
        final target = Directory(p.join(parent.path, 'target'));
        File(p.join(stage.path, 'payload')).writeAsStringSync('source');
        if (kind == 'file') {
          File(target.path).writeAsStringSync('keep');
        } else if (kind == 'alias') {
          Link(target.path).createSync('missing-target');
        } else {
          target.createSync();
          if (kind == 'nonempty')
            File(p.join(target.path, 'keep')).writeAsStringSync('keep');
        }
        expect(
          () => publishDirectory(stage, target),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'reported native error',
              isNotNull,
            ),
          ),
        );
        expect(
          FileSystemEntity.typeSync(stage.path, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(stage.listSync().map((entry) => p.basename(entry.path)), [
          'payload',
        ]);
        expect(
          FileSystemEntity.typeSync(
            p.join(stage.path, 'payload'),
            followLinks: false,
          ),
          FileSystemEntityType.file,
        );
        expect(
          File(p.join(stage.path, 'payload')).readAsStringSync(),
          'source',
        );
        expect(
          FileSystemEntity.typeSync(target.path, followLinks: false),
          kind == 'file'
              ? FileSystemEntityType.file
              : kind == 'alias'
              ? FileSystemEntityType.link
              : FileSystemEntityType.directory,
        );
        if (kind == 'file') {
          expect(File(target.path).readAsStringSync(), 'keep');
        } else if (kind == 'alias') {
          expect(Link(target.path).targetSync(), 'missing-target');
        } else {
          expect(
            target.listSync().map((entry) => p.basename(entry.path)),
            kind == 'empty' ? <String>[] : ['keep'],
          );
          if (kind == 'nonempty') {
            final keep = File(p.join(target.path, 'keep'));
            expect(
              FileSystemEntity.typeSync(keep.path, followLinks: false),
              FileSystemEntityType.file,
            );
            expect(keep.readAsStringSync(), 'keep');
          }
        }
      }
    },
  );

  test('unrepresentable names cannot truncate or substitute a destination', () {
    for (final suffix in ['\x00hidden', '\uD800']) {
      final stage = Directory(p.join(root.path, 'stage'))..createSync();
      expect(
        () => publishDirectory(
          stage,
          Directory(p.join(root.path, 'target$suffix')),
        ),
        throwsFormatException,
      );
      expect(stage.existsSync(), isTrue);
      expect(Directory(p.join(root.path, 'target')).existsSync(), isFalse);
      stage.deleteSync();
    }
  });

  test('refuses non-directory staging and non-sibling publication', () {
    final file = File(p.join(root.path, 'file'))..writeAsStringSync('source');
    expect(
      () => publishDirectory(
        Directory(file.path),
        Directory(p.join(root.path, 'new')),
      ),
      throwsFormatException,
    );
    expect(file.readAsStringSync(), 'source');
    final stage = Directory(p.join(root.path, 'stage'))..createSync();
    final other = Directory(p.join(root.path, 'other'))..createSync();
    expect(
      () => publishDirectory(stage, Directory(p.join(other.path, 'published'))),
      throwsFormatException,
    );
    expect(stage.existsSync(), isTrue);
    expect(other.listSync(), isEmpty);
  });

  test('publication transfers a complete sibling directory unchanged', () {
    final stage = Directory(p.join(root.path, 'prepared café'))..createSync();
    final destination = Directory(p.join(root.path, 'published café'));
    File(p.join(stage.path, 'payload')).writeAsStringSync('complete');
    publishDirectory(stage, destination);
    expect(stage.existsSync(), isFalse);
    expect(
      File(p.join(destination.path, 'payload')).readAsStringSync(),
      'complete',
    );
  });

  test('publication retains noncanonical route witnesses', () {
    final stage = Directory(p.join(root.path, 'stage'))..createSync();
    final child = Directory(p.join(root.path, 'child'))..createSync();
    final alias = Link(p.join(root.path, 'hop'))..createSync(child.path);
    final target = Directory(p.join(root.path, 'published'));
    for (final path in [
      '${root.path}${p.separator}.${p.separator}stage',
      '${child.path}${p.separator}..${p.separator}stage',
      '${alias.path}${p.separator}..${p.separator}stage',
      if (Platform.isWindows) '${root.path}/stage',
    ]) {
      expect(Directory(path).resolveSymbolicLinksSync(), stage.path);
      expect(
        () => publishDirectory(Directory(path), target),
        throwsFormatException,
      );
      expect(stage.existsSync(), isTrue);
      expect(target.existsSync(), isFalse);
    }
  });

  test('source and parent aliases cannot redirect publication', () {
    final stage = Directory(p.join(root.path, 'stage'))..createSync();
    final alias = Link(p.join(root.path, 'alias'))..createSync(stage.path);
    final parentAlias = Link(p.join(root.path, 'parent-alias'))
      ..createSync(root.path);
    for (final source in [
      Directory(alias.path),
      Directory(p.join(parentAlias.path, 'stage')),
    ]) {
      expect(
        () =>
            publishDirectory(source, Directory(p.join(root.path, 'published'))),
        throwsFormatException,
      );
      expect(stage.existsSync(), isTrue);
      expect(Directory(p.join(root.path, 'published')).existsSync(), isFalse);
    }
    expect(Link(alias.path).targetSync(), stage.path);
  });

  test('long native paths retain Unicode names without truncation', () {
    final parent = Directory(
      p.joinAll([root.path, ...List.filled(4, 'long-café-' * 8)]),
    )..createSync(recursive: true);
    final stage = Directory(p.join(parent.path, 'stage'))..createSync();
    final target = Directory(p.join(parent.path, 'published-😀'));
    File(p.join(stage.path, 'payload')).writeAsStringSync('long path');
    publishDirectory(stage, target);
    expect(
      File(p.join(target.path, 'payload')).readAsStringSync(),
      'long path',
    );
    expect(stage.existsSync(), isFalse);
  });

  test('two ready processes contend for exactly one complete publication', () async {
    final script = File(p.join(root.path, 'publisher.dart'))
      ..writeAsStringSync('''
import 'dart:io';
import '${File('tool/release/publish_directory.dart').absolute.uri}';
Future<void> main(List<String> args) async {
  File(args[2]).writeAsStringSync('ready');
  final deadline = Stopwatch()..start();
  while (!File(args[3]).existsSync()) {
    if (deadline.elapsed > const Duration(seconds: 10)) throw StateError('No release');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  try {
    publishDirectory(Directory(args[0]), Directory(args[1]));
    stdout.write('published');
  } on FileSystemException catch (error) {
    stderr.write(error.osError?.errorCode);
    exitCode = 23;
  }
}
''');
    final target = Directory(p.join(root.path, 'published'));
    final release = File(p.join(root.path, 'release'));
    final stages = [
      for (var i = 0; i < 2; i++)
        Directory(p.join(root.path, 'stage$i'))..createSync(),
    ];
    final ready = [
      for (var i = 0; i < 2; i++) File(p.join(root.path, 'ready$i')),
    ];
    final running = <Process>{};
    final exits = <Future<int>>[],
        outputs = <Future<String>>[],
        errors = <Future<String>>[];
    try {
      for (var i = 0; i < 2; i++) {
        File(p.join(stages[i].path, 'owner')).writeAsStringSync('$i');
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          script.path,
          stages[i].path,
          target.path,
          ready[i].path,
          release.path,
        ]);
        running.add(process);
        exits.add(process.exitCode.whenComplete(() => running.remove(process)));
        outputs.add(process.stdout.transform(utf8.decoder).join());
        errors.add(process.stderr.transform(utf8.decoder).join());
      }
      final deadline = Stopwatch()..start();
      while (ready.any((file) => !file.existsSync())) {
        if (deadline.elapsed > const Duration(seconds: 10))
          fail('Publishers did not become ready');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(target.existsSync(), isFalse);
      release.writeAsStringSync('go');
      final codes = await Future.wait(exits)
          .timeout(const Duration(seconds: 10));
      expect(codes.toList()..sort(), [0, 23]);
      final winner = codes.indexOf(0), loser = codes.indexOf(23);
      expect(await outputs[winner], 'published');
      expect(await errors[winner], isEmpty);
      expect(int.tryParse(await errors[loser]), isNotNull);
      expect(
        FileSystemEntity.typeSync(target.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(target.listSync().map((entry) => p.basename(entry.path)), [
        'owner',
      ]);
      expect(
        FileSystemEntity.typeSync(
          p.join(target.path, 'owner'),
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
      expect(File(p.join(target.path, 'owner')).readAsStringSync(), '$winner');
      expect(
        FileSystemEntity.typeSync(stages[winner].path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(
        FileSystemEntity.typeSync(stages[loser].path, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(stages[loser].listSync().map((entry) => p.basename(entry.path)), [
        'owner',
      ]);
      expect(
        FileSystemEntity.typeSync(
          p.join(stages[loser].path, 'owner'),
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
      expect(
        File(p.join(stages[loser].path, 'owner')).readAsStringSync(),
        '$loser',
      );
    } finally {
      for (final process in running.toList()) terminateProcessId(process.pid);
      await Future.wait(exits).timeout(const Duration(seconds: 5));
    }
  });
}
