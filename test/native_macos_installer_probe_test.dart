import 'dart:ffi';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/native_macos_installer_probe.dart';

void fixtureTest(String name, Future<void> Function() body) => test(
  name,
  body,
  skip: Platform.isWindows ? 'POSIX macOS installer lifecycle fixture' : false,
);

void main() {
  test(
    'native lifecycle refuses wrong host before output or commands',
    () async {
      final root = await Directory.systemTemp.createTemp('macos-refusal-');
      try {
        final output = Directory('${root.path}/untouched');
        await expectLater(
          runMacosInstaller(
            version: '0.1.0',
            repository: root,
            builderDart: File(Platform.resolvedExecutable),
            bundle: Directory('${root.path}/missing'),
            output: output,
            inspect: (_, _) async => throw StateError('must not inspect'),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('native macOS arm64'),
            ),
          ),
        );
        expect(await output.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: Platform.isMacOS && Abi.current() == Abi.macosArm64
        ? 'Non-native macOS host control'
        : false,
  );
  fixtureTest('synthetic lifecycle builds old then final, upgrades and removes owned files', () async {
    final root = Directory(
      await (await Directory.systemTemp.createTemp('macos-fixture-'))
          .resolveSymbolicLinks(),
    );
    try {
      final fixture = Fixture(root);
      await fixture.prepare();
      final alias = Link('${root.path}/temporary-alias');
      await alias.create(root.path);
      fixture.temporaryParent = Directory(alias.path);
      fixture.beforeRun = (args) async {
        if (args.first == fixture.dart.path) {
          final input = Directory(args[args.indexOf('--bundle') + 1]);
          expect(
            input.path,
            await input.resolveSymbolicLinks(),
            reason: 'Installer builder requires a canonical bundle',
          );
          expect(
            Directory(args.last).parent.path,
            await Directory(args.last).parent.resolveSymbolicLinks(),
          );
        }
      };
      final result = await fixture.exercise();
      expect(fixture.inspected, isTrue);
      expect(fixture.calls.map((a) => a.first == 'sudo' ? a[2] : a.first), [
        '/usr/sbin/pkgutil',
        '/usr/bin/sw_vers',
        Platform.resolvedExecutable,
        Platform.resolvedExecutable,
        '/usr/sbin/installer',
        '/bin/cp',
        '/usr/sbin/installer',
        '/bin/sh',
        '/usr/sbin/pkgutil',
        '/bin/rm',
        '/bin/rmdir',
      ]);
      for (final call in fixture.calls.where((a) => a.first == 'sudo')) {
        expect(call[1], '-n');
      }
      for (final call in fixture.calls.where(
        (a) => a.first == Platform.resolvedExecutable,
      )) {
        expect(call[1], '${root.path}/tool/installers/macos/build.dart');
      }

      expect(result['cases'], [
        'install-old',
        'upgrade-final',
        'installed-command',
        'remove',
        'foreign-preserved',
      ]);
      expect((result['old_fixture'] as Map)['version'], '0.0.0');
      expect((result['compiler'] as Map)['version'], contains('fixture OS'));
      expect(await fixture.installed.exists(), isFalse);
      expect(
        fixture.calls.where((a) => a.contains('/bin/cp')).single.length,
        5,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
  fixtureTest(
    'filesystem refusals include dangling links and precede output or commands',
    () async {
      for (final kind in [
        'root',
        'command',
        'output',
        'relative-dart',
        'nested',
        'aliased-nested',
        'bundle-itself',
      ]) {
        final root = await Directory.systemTemp.createTemp('macos-refusal-');
        try {
          final f = Fixture(root);
          await f.prepare();
          if (kind == 'root') await Link(f.installed.path).create('missing');
          if (kind == 'command') {
            await f.command.parent.create();
            await Link(f.command.path).create('missing');
          }
          if (kind == 'output') await f.output.create();
          if (kind == 'relative-dart') {
            f.dart = File(p.relative(Platform.resolvedExecutable));
            expect(f.dart.isAbsolute, isFalse);
            expect(await f.dart.exists(), isTrue);
          }
          final originalManifest = await File('${f.bundle.path}/manifest.json')
              .readAsString();
          if (kind == 'nested')
            f.output = Directory('${f.bundle.path}/new/output');
          if (kind == 'aliased-nested') {
            await Link('${root.path}/alias').create(f.bundle.path);
            f.output = Directory('${root.path}/alias/new/output');
          }
          if (kind == 'bundle-itself') f.output = f.bundle;

          await expectLater(f.exercise(), throwsFormatException);
          expect(f.calls, isEmpty);
          expect(
            await f.output.exists(),
            kind == 'output' || kind == 'bundle-itself',
          );
          expect(await Directory('${f.bundle.path}/new').exists(), isFalse);
          expect(
            await File('${f.bundle.path}/manifest.json').readAsString(),
            originalManifest,
          );
          expect((await f.bundle.list().toList()).length, 2);
        } finally {
          await root.delete(recursive: true);
        }
      }
    },
  );
  fixtureTest(
    'receipt query failures never permit compiler or installation commands',
    () async {
      final root = await Directory.systemTemp.createTemp('macos-receipt-');
      try {
        final f = Fixture(root);
        await f.prepare();
        f.beforeRun = (args) async {
          throw ProcessException(
            args.first,
            args.skip(1).toList(),
            'receipt refusal',
            2,
          );
        };
        await expectLater(f.exercise(), throwsA(isA<ProcessException>()));
        expect(f.calls.single, [
          '/usr/sbin/pkgutil',
          '--pkg-info',
          'org.archway.cli',
        ]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  fixtureTest(
    'verified fallback cleans failed inspect and preserves primary failure',
    () async {
      for (final corrupt in [false, true]) {
        final root = await Directory.systemTemp.createTemp('macos-cleanup-');
        try {
          final f = Fixture(root);
          await f.prepare();
          final primary = StateError('primary inspection failure');
          f.duringInspect = () async {
            final script = File('${f.installed.path}/uninstall.sh');
            if (corrupt) {
              await script.writeAsString('untrusted');
            } else {
              await script.delete();
            }
            throw primary;
          };
          await expectLater(f.exercise(), throwsA(same(primary)));
          final uninstalls = f.calls
              .where((a) => a.contains('/bin/sh'))
              .toList();
          expect(uninstalls.length, corrupt ? 0 : 1);
          if (!corrupt)
            expect(uninstalls.single.last, contains('final-build/root/'));
          expect(await f.installed.exists(), corrupt);
          expect(
            await root.list().any((e) => e.path.contains('archway pkg ')),
            isFalse,
          );
        } finally {
          await root.delete(recursive: true);
        }
      }
    },
  );
  fixtureTest(
    'mixed root preserves unrelated bytes and only removes exact marker',
    () async {
      final root = await Directory.systemTemp.createTemp('macos-mixed-');
      try {
        final f = Fixture(root);
        await f.prepare();
        f.duringInspect = () async {
          await File('${f.installed.path}/unrelated.txt').writeAsString('keep');
        };
        await f.exercise();
        expect(
          await File('${f.installed.path}/unrelated.txt').readAsString(),
          'keep',
        );
        expect(f.calls.where((a) => a.contains('/bin/rm')).map((a) => a.last), [
          '${f.installed.path}/user-notes.txt',
        ]);
        expect(f.calls.any((a) => a.contains('/bin/rmdir')), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  fixtureTest(
    'temporary cleanup cannot replace an active primary failure',
    () async {
      final root = await Directory.systemTemp.createTemp('macos-primary-');
      try {
        final f = Fixture(root);
        await f.prepare();
        final primary = StateError('primary');
        var deleteAttempts = 0;
        f.duringInspect = () async {
          throw primary;
        };
        f.deleteTemporary = (directory) async {
          expect(await directory.exists(), isTrue);
          deleteAttempts++;
          throw FileSystemException(
            'injected cleanup delete failure',
            directory.path,
          );
        };
        await expectLater(f.exercise(), throwsA(same(primary)));
        expect(deleteAttempts, 1);
        expect(
          await root.list().any((e) => e.path.contains('archway pkg ')),
          isTrue,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}

// All command effects below are in a private temporary directory. No native
// installer, sudo, pkgutil or /usr/local mutation is performed by these tests.
class Fixture {
  Fixture(this.root);
  final Directory root;
  late Directory temporaryParent = root;
  final calls = <List<String>>[];
  late final bundle = Directory('${root.path}/bundle');
  late Directory output = Directory('${root.path}/output');
  late final installed = Directory('${root.path}/installed');
  late final command = File('${root.path}/bin/archway');
  late final compiler = File('${root.path}/pkgbuild');
  final builds = <String, Directory>{};
  Future<void> Function(List<String>)? beforeRun;
  Future<void> Function()? duringInspect;
  Future<void> Function(Directory)? deleteTemporary;
  bool inspected = false;
  File dart = File(Platform.resolvedExecutable);
  Future<void> prepare() async {
    await bundle.create();
    await compiler.writeAsString('compiler');
    await File('${bundle.path}/README.txt').writeAsString('payload');
    await File('${bundle.path}/manifest.json').writeAsString(
      jsonEncode({
        'version': '0.1.0',
        'files': {
          'README.txt': {
            'sha256': sha256.convert(utf8.encode('payload')).toString(),
            'mode': 420,
            'size': 7,
          },
        },
      }),
    );
  }

  Future<String> run(
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    int expectedExit = 0,
  }) async {
    calls.add([...args]);
    await beforeRun?.call(args);
    if (args.first == '/usr/sbin/pkgutil') {
      expect(expectedExit, 1);
      return '';
    }
    if (args.first == '/usr/bin/sw_vers') return 'fixture OS';
    if (args.first == dart.path) {
      final source = Directory(args[args.indexOf('--bundle') + 1]);
      final stage = Directory(args.last);
      final version = source.path.endsWith('test-only-old-bundle')
          ? '0.0.0'
          : '0.1.0';
      final pkg = '${stage.path}/archway-$version-macos-arm64-unsigned.pkg';
      await stage.create(recursive: true);
      await File(pkg).writeAsString(version);
      final uninstall = File(
        '${stage.path}/root/usr/local/lib/archway/uninstall.sh',
      );
      await uninstall.parent.create(recursive: true);
      await uninstall.writeAsString('verified uninstaller');
      builds[pkg] = source;
    } else if (args.contains('/usr/sbin/installer')) {
      final pkg = args[args.indexOf('-pkg') + 1];
      final old = pkg.contains('0.0.0');
      await installed.create(recursive: true);
      final stale = File('${installed.path}/obsolete/installer-probe..txt');
      if (old) {
        await stale.parent.create();
        await stale.writeAsString(
          'Test-only previous-generation owned file.\n',
        );
      } else if (await stale.exists()) {
        await stale.delete();
        await stale.parent.delete();
      }
      await File('${bundle.path}/README.txt')
          .copy('${installed.path}/README.txt');
      await File(
        '${installed.path}/manifest.json',
      ).writeAsBytes(await File('${bundle.path}/manifest.json').readAsBytes());
      await File('${installed.path}/uninstall.sh')
          .writeAsString('verified uninstaller');
      await command.parent.create(recursive: true);
      if (await FileSystemEntity.type(command.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await Link(command.path)
            .create('${installed.path}/bin/macos-arm64/archway');
      }
    } else if (args.contains('/bin/cp')) {
      await File(args[3]).copy(args[4]);
    } else if (args.contains('/bin/sh')) {
      for (final name in ['manifest.json', 'uninstall.sh', 'README.txt']) {
        final file = File('${installed.path}/$name');
        if (await file.exists()) await file.delete();
      }
      if (await FileSystemEntity.type(command.path, followLinks: false) ==
          FileSystemEntityType.link)
        await Link(command.path).delete();
    } else if (args.contains('/bin/rm')) {
      await File(args.last).delete();
    } else if (args.contains('/bin/rmdir')) {
      await Directory(args.last).delete();
    } else {
      throw StateError('Unexpected command $args');
    }
    return '';
  }

  Future<Map<String, Object?>> exercise() => exerciseMacosInstaller(
    version: '0.1.0',
    repository: root,
    builderDart: dart,
    bundle: bundle,
    output: output,
    installed: installed,
    command: command,
    compiler: compiler,
    temporaryParent: temporaryParent,
    run: run,
    commands: () => const [],
    deleteTemporary: deleteTemporary,
    inspect: (file, directory) async {
      expect(file.path, command.path);
      expect(directory.path, installed.path);
      await duringInspect?.call();
      inspected = true;
      return {'checked': true};
    },
  );
}
