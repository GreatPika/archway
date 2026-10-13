import 'dart:convert';
import 'dart:io';

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
        final parent = Directory('${root.path}/$kind')..createSync();
        final stage = Directory('${parent.path}/stage')..createSync();
        final target = Directory('${parent.path}/target');
        File('${stage.path}/payload').writeAsStringSync('source');
        if (kind == 'file') {
          File(target.path).writeAsStringSync('keep');
        } else if (kind == 'alias') {
          Link(target.path).createSync('missing-target');
        } else {
          target.createSync();
          if (kind == 'nonempty')
            File('${target.path}/keep').writeAsStringSync('keep');
        }
        expect(
          () => publishDirectory(stage, target),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'captured native error',
              greaterThan(0),
            ),
          ),
        );
        expect(File('${stage.path}/payload').readAsStringSync(), 'source');
        if (kind == 'file') {
          expect(File(target.path).readAsStringSync(), 'keep');
        } else if (kind == 'alias') {
          expect(Link(target.path).targetSync(), 'missing-target');
        } else {
          expect(target.listSync().length, kind == 'empty' ? 0 : 1);
        }
      }
    },
  );

  test('unrepresentable names cannot truncate or substitute a destination', () {
    for (final suffix in ['\x00hidden', '\uD800']) {
      final stage = Directory('${root.path}/stage')..createSync();
      expect(
        () => publishDirectory(stage, Directory('${root.path}/target$suffix')),
        throwsFormatException,
      );
      expect(stage.existsSync(), isTrue);
      expect(Directory('${root.path}/target').existsSync(), isFalse);
      stage.deleteSync();
    }
  });

  test('refuses non-directory staging and non-sibling publication', () {
    final file = File('${root.path}/file')..writeAsStringSync('source');
    expect(
      () =>
          publishDirectory(Directory(file.path), Directory('${root.path}/new')),
      throwsFormatException,
    );
    expect(file.readAsStringSync(), 'source');
    final stage = Directory('${root.path}/stage')..createSync();
    final other = Directory('${root.path}/other')..createSync();
    expect(
      () => publishDirectory(stage, Directory('${other.path}/published')),
      throwsFormatException,
    );
    expect(stage.existsSync(), isTrue);
    expect(other.listSync(), isEmpty);
  });

  test('publication transfers a complete sibling directory unchanged', () {
    final stage = Directory('${root.path}/prepared café')..createSync();
    final destination = Directory('${root.path}/published café');
    File('${stage.path}/payload').writeAsStringSync('complete');
    publishDirectory(stage, destination);
    expect(stage.existsSync(), isFalse);
    expect(File('${destination.path}/payload').readAsStringSync(), 'complete');
  });

  test('source and parent aliases cannot redirect publication', () {
    final stage = Directory('${root.path}/stage')..createSync();
    final alias = Link('${root.path}/alias')..createSync(stage.path);
    final parentAlias = Link('${root.path}/parent-alias')
      ..createSync(root.path);
    for (final source in [
      Directory(alias.path),
      Directory('${parentAlias.path}/stage'),
    ]) {
      expect(
        () => publishDirectory(source, Directory('${root.path}/published')),
        throwsFormatException,
      );
      expect(stage.existsSync(), isTrue);
      expect(Directory('${root.path}/published').existsSync(), isFalse);
    }
    expect(Link(alias.path).targetSync(), stage.path);
  });

  test('long native paths retain Unicode names without truncation', () {
    final parent = Directory(
      '${root.path}/${List.filled(4, 'long-café-' * 8).join('/')}',
    )..createSync(recursive: true);
    final stage = Directory('${parent.path}/stage')..createSync();
    final target = Directory('${parent.path}/published-😀');
    File('${stage.path}/payload').writeAsStringSync('long path');
    publishDirectory(stage, target);
    expect(File('${target.path}/payload').readAsStringSync(), 'long path');
    expect(stage.existsSync(), isFalse);
  });

  test('two ready processes contend for exactly one complete publication', () async {
    final script = File('${root.path}/publisher.dart')
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
    final target = Directory('${root.path}/published');
    final release = File('${root.path}/release');
    final stages = [
      for (var i = 0; i < 2; i++)
        Directory('${root.path}/stage$i')..createSync(),
    ];
    final ready = [for (var i = 0; i < 2; i++) File('${root.path}/ready$i')];
    final running = <Process>{};
    final exits = <Future<int>>[],
        outputs = <Future<String>>[],
        errors = <Future<String>>[];
    try {
      for (var i = 0; i < 2; i++) {
        File('${stages[i].path}/owner').writeAsStringSync('$i');
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
      expect(int.parse(await errors[loser]), greaterThan(0));
      expect(File('${target.path}/owner').readAsStringSync(), '$winner');
      expect(stages[winner].existsSync(), isFalse);
      expect(File('${stages[loser].path}/owner').readAsStringSync(), '$loser');
    } finally {
      for (final process in running.toList()) terminateProcessId(process.pid);
      await Future.wait(exits).timeout(const Duration(seconds: 5));
    }
  });
}
