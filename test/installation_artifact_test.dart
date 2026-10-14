import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/release/archive_input.dart';
import '../tool/release/installation_artifact.dart';
import 'support/native_file_fixtures.dart';

const name = 'bin/linux-x64/archway';
const hello =
    '5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03';

void main() {
  late Directory base, bundle, destination;
  late File binary;
  setUp(() {
    base = Directory(
      Directory.systemTemp
          .createTempSync('export-test-')
          .resolveSymbolicLinksSync(),
    );
    bundle = Directory(p.join(base.path, 'relocated ü installation'));
    binary = File(p.joinAll([bundle.path, ...name.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('hello\n');
    if (!Platform.isWindows) posix.chmod(binary.path, '751');
    destination = Directory(p.join(base.path, 'artifact'));
  });
  tearDown(() => base.deleteSync(recursive: true));
  Future<void> export(Future<void> Function(Directory, Directory) verify) =>
      exportInstallation(bundle, destination, {name}, {}, verify);
  Iterable<FileSystemEntity> stages() => base.listSync().where(
    (e) => p.basename(e.path).startsWith('.archway-artifact-'),
  );
  void cleaned() {
    expect(destination.existsSync(), isFalse);
    expect(stages(), isEmpty);
  }

  test(
    'transport preserves bytes and observed mode before publication',
    () async {
      late Directory workspace;
      await exportInstallation(
        bundle,
        destination,
        {name},
        {'target': 'linux-x64'},
        (extracted, freshBase) async {
          workspace = freshBase;
          expect(destination.existsSync(), isFalse);
          expect(freshBase.listSync().map((e) => e.path), [extracted.path]);
          final file = File(p.joinAll([extracted.path, ...name.split('/')]));
          final route = p.relative(
            file.path,
            from: Directory.systemTemp.resolveSymbolicLinksSync(),
          );
          expect(route, contains(' '));
          expect(route, contains('café'));
          expect(file.readAsStringSync(), 'hello\n');
          if (!Platform.isWindows) {
            expect(file.statSync().mode & 0xfff, 0x1e9);
            expect(freshBase.statSync().mode & 0xfff, 0x1c0);
          }
        },
      );
      expect(workspace.existsSync(), isFalse);
      expect(
        destination.listSync().map((e) => p.basename(e.path)).toList()..sort(),
        ['installation.tar', 'provenance.json'],
      );
      final archive = File(p.join(destination.path, 'installation.tar'));
      final record = jsonDecode(
        File(p.join(destination.path, 'provenance.json')).readAsStringSync(),
      );
      expect(record['files'][name]['sha256'], hello);
      expect(record['files'][name]['size'], 6);
      expect(record['archive'], {
        'name': 'installation.tar',
        'sha256': (await sha256.bind(archive.openRead()).first).toString(),
      });
      final reader = TarReader(archive.openRead());
      try {
        expect(await reader.moveNext(), isTrue);
        expect(reader.current.name, name);
        expect(
          await utf8.decoder.bind(reader.current.contents).join(),
          'hello\n',
        );
        expect(await reader.moveNext(), isFalse);
      } finally {
        await reader.cancel();
      }
    },
  );
  test('failed acceptance cleans only owned staging and workspace', () async {
    final unrelated = Directory(
      p.join(base.path, '.archway-artifact-unrelated'),
    )..createSync();
    late Directory workspace;
    final failure = StateError('transport init failed');
    await expectLater(
      export((_, freshBase) async {
        workspace = freshBase;
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(workspace.existsSync(), isFalse);
    expect(destination.existsSync(), isFalse);
    expect(stages().map((e) => e.path), [unrelated.path]);
  });
  test(
    'existing destinations and a racing callback never get replaced',
    () async {
      for (final alias in [false, true]) {
        if (alias) {
          Link(destination.path).createSync('missing');
        } else {
          destination.createSync();
        }
        await expectLater(
          export((_, _) async => fail('Existing target reached acceptance')),
          throwsA(isA<FileSystemException>()),
        );
        if (alias) {
          expect(Link(destination.path).targetSync(), 'missing');
          Link(destination.path).deleteSync();
        } else {
          expect(destination.listSync(), isEmpty);
          destination.deleteSync();
        }
        cleaned();
      }
      await expectLater(
        export((_, _) async {
          destination.createSync();
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(destination.listSync(), isEmpty);
      destination.deleteSync();
      cleaned();
    },
  );
  test(
    'source inventory refuses aliases, special, extra and missing entries',
    () async {
      for (final kind in [
        'alias',
        'special',
        'empty-directory',
        'extra',
        'missing',
      ]) {
        final extra = p.join(bundle.path, 'unexpected');
        if (kind == 'alias') {
          binary.deleteSync();
          Link(binary.path).createSync(
            (File(
              p.join(base.path, 'outside'),
            )..writeAsStringSync('hello\n')).path,
          );
        }
        if (kind == 'special') {
          binary.deleteSync();
          createNonregularResource(binary.path);
        }
        if (kind == 'empty-directory') Directory(extra).createSync();
        if (kind == 'extra') File(extra).writeAsStringSync('extra');
        if (kind == 'missing') binary.deleteSync();
        await expectLater(
          export((_, _) async => fail('Invalid source reached acceptance')),
          throwsFormatException,
        );
        cleaned();
        if (kind == 'alias') Link(binary.path).deleteSync();
        if (kind == 'special') removeNonregularResource(binary.path);
        if (kind == 'empty-directory') Directory(extra).deleteSync();
        if (kind == 'extra') File(extra).deleteSync();
        if (kind == 'alias' || kind == 'special' || kind == 'missing')
          binary.writeAsStringSync('hello\n');
      }
    },
  );
  test(
    'changed or over-budget streams stop before owned staging cleanup',
    () async {
      final directory = Directory(p.join(base.path, 'stream-source'))
        ..createSync();
      final file = File(p.join(directory.path, 'payload'));
      for (final replacement in ['grown!!', 'short', 'HELLO\n', null]) {
        file.writeAsStringSync('hello\n');
        final source = _ReadProbe(
          file,
          () {
            if (replacement != null) file.writeAsStringSync(replacement);
          },
          () {
            expect(stages(), isNotEmpty);
          },
        );
        await expectLater(
          exportInstallation(
            _OneFileDirectory(directory, source),
            destination,
            {'payload'},
            {},
            (_, _) async => fail('Invalid stream reached acceptance'),
            maxBytes: replacement == null ? 515 : 4096,
          ),
          throwsFormatException,
        );
        expect(source.reads, 2);
        expect(source.stopped, isTrue);
        cleaned();
      }
    },
  );
  test(
    'Unicode PAX and provenance identities ignore order and source time',
    () async {
      final long = 'assets/${'café' * 26}.txt';
      File(p.joinAll([bundle.path, ...long.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('guide');
      final hashes = <List<String>>[];
      for (final reverse in [false, true]) {
        binary.setLastModifiedSync(DateTime.utc(reverse ? 2025 : 2024));
        destination = Directory(p.join(base.path, 'artifact-$reverse'));
        await exportInstallation(
          bundle,
          destination,
          (reverse ? [name, long] : [long, name]).toSet(),
          {
            'nested': reverse ? {'z': 2, 'a': 1} : {'a': 1, 'z': 2},
            'schema_version': 999,
          },
          (_, _) async {},
        );
        hashes.add([
          for (final path in ['installation.tar', 'provenance.json'])
            sha256
                .convert(File(p.join(destination.path, path)).readAsBytesSync())
                .toString(),
        ]);
      }
      expect(hashes[0], hashes[1]);
      final reader = TarReader(
        File(p.join(destination.path, 'installation.tar')).openRead(),
      );
      try {
        expect(await reader.moveNext(), isTrue);
        expect(reader.current.name, long);
        expect(reader.current.modified.millisecondsSinceEpoch, 0);
        expect(reader.current.header.userId, 0);
        expect(reader.current.header.groupId, 0);
      } finally {
        await reader.cancel();
      }
      final record = jsonDecode(
        File(p.join(destination.path, 'provenance.json')).readAsStringSync(),
      );
      expect(record['schema_version'], 1);
    },
  );
  test(
    'source and encoded provenance bounds reject without publication',
    () async {
      for (final limit in [5, -1, maxArchiveBytes + 1]) {
        await expectLater(
          exportInstallation(
            bundle,
            destination,
            {name},
            {},
            (_, _) async => fail('Oversize source reached acceptance'),
            maxBytes: limit,
          ),
          limit == 5 ? throwsFormatException : throwsArgumentError,
        );
        cleaned();
      }
      await expectLater(
        exportInstallation(
          bundle,
          destination,
          {name},
          {'oversize': 'x' * maxArchiveJsonBytes},
          (_, _) async {},
        ),
        throwsFormatException,
      );
      cleaned();
    },
  );
}

// Real-file read probes, with a single-file directory enumeration for injection.
final class _OneFileDirectory implements Directory {
  _OneFileDirectory(this.directory, this.file);
  final Directory directory;
  final File file;
  @override
  String get path => directory.path;
  @override
  Directory get absolute => directory.absolute;
  @override
  Future<String> resolveSymbolicLinks() => directory.resolveSymbolicLinks();
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.value(file);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReadProbe implements File {
  _ReadProbe(this.file, this.beforeWrite, this.beforeStop);
  final File file;
  final void Function() beforeWrite, beforeStop;
  var reads = 0, stopped = false;
  @override
  String get path => file.path;
  @override
  File get absolute => file.absolute;
  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    final writing = ++reads == 2;
    if (writing) beforeWrite();
    try {
      yield* file.openRead(start, end);
    } finally {
      if (writing) {
        await Future<void>.delayed(Duration.zero);
        beforeStop();
        stopped = true;
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
