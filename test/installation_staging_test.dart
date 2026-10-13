import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/installation_staging.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('archway-staging-'));
  tearDown(() => root.deleteSync(recursive: true));

  File fixture(String relative) {
    final binary = File(p.join(root.path, 'source', relative));
    binary.parent.createSync(recursive: true);
    binary.writeAsStringSync('actual executable');
    for (final directory in ['native/windows-x64', 'assets/typescript']) {
      final asset = File(p.join(root.path, 'source', directory, 'fixture'));
      asset.parent.createSync(recursive: true);
      asset.writeAsStringSync('asset');
    }
    return binary;
  }

  test('copies the actual Windows archive layout', () {
    final binary = fixture('bin/windows-x64/archway.exe');
    final destination = Directory(p.join(root.path, 'relocated café'));
    final staged = stageInstallation(binary, destination);
    expect(
      p.relative(staged.path, from: destination.path),
      p.join('bin', 'windows-x64', 'archway.exe'),
    );
    expect(staged.readAsBytesSync(), utf8.encode('actual executable'));
    expect(
      File(p.join(destination.path, 'native/windows-x64/fixture'))
          .readAsBytesSync(),
      utf8.encode('asset'),
    );
  });

  for (final relative in [
    'bin/windows-x64/archway',
    'bin/linux-x64/archway.exe',
    'bin/unknown/archway',
  ]) {
    test('rejects unrecognized or mismatched layout: $relative', () {
      final binary = fixture(relative);
      final destination = Directory(p.join(root.path, 'destination'));
      expect(() => stageInstallation(binary, destination), throwsArgumentError);
      expect(destination.existsSync(), isFalse);
    });
  }

  test('copies universal macOS layout without relabeling', () {
    final binary = fixture('bin/macos-universal/archway');
    binary.writeAsStringSync('universal binary');
    final destination = Directory(p.join(root.path, 'destination'));
    final staged = stageInstallation(binary, destination);
    expect(
      p.relative(staged.path, from: destination.path),
      p.join('bin', 'macos-universal', 'archway'),
    );
    expect(staged.readAsBytesSync(), utf8.encode('universal binary'));
  });

  test('does not merge into pre-existing installation directories', () {
    final binary = fixture('bin/linux-x64/archway');
    for (final directory in ['bin/linux-x64', 'native', 'assets']) {
      final destination = Directory(
        p.join(root.path, directory.replaceAll('/', '-')),
      );
      final marker = File(p.join(destination.path, directory, 'kept'));
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('untouched');
      expect(
        () => stageInstallation(binary, destination),
        throwsA(isA<FileSystemException>()),
      );
      expect(marker.readAsStringSync(), 'untouched');
    }
  });

  test('preserves raw, dangling and cyclic symbolic-link targets', () {
    final binary = fixture('bin/linux-x64/archway');
    final assets = Directory(p.join(root.path, 'source/assets'));
    final separator = Platform.pathSeparator;
    final targets = {
      'relative':
          '.${separator}typescript$separator..${separator}typescript'
          '${separator}fixture',
      'dangling': 'missing-target',
      'cycle': 'cycle',
      'directory': p.join(assets.path, 'typescript'),
    };
    for (final entry in targets.entries) {
      Link(p.join(assets.path, entry.key)).createSync(entry.value);
    }
    final destination = Directory(p.join(root.path, 'destination'));
    stageInstallation(binary, destination);
    for (final entry in targets.entries) {
      final copied = Link(p.join(destination.path, 'assets', entry.key));
      expect(copied.existsSync(), isTrue);
      expect(copied.targetSync(), entry.value);
    }
    expect(
      File(p.join(destination.path, 'assets/relative')).readAsStringSync(),
      'asset',
    );
  });

  test('infers symbolic-link directory type at the destination', () {
    final binary = fixture('bin/linux-x64/archway');
    File(p.join(root.path, 'source/unshipped'))
        .writeAsStringSync('source file');
    final target = '..${Platform.pathSeparator}unshipped';
    Link(p.join(root.path, 'source/assets/alias')).createSync(target);
    final destination = Directory(p.join(root.path, 'destination'))
      ..createSync();
    Directory(p.join(destination.path, 'unshipped')).createSync();
    stageInstallation(binary, destination);
    final alias = Link(p.join(destination.path, 'assets/alias'));
    expect(alias.targetSync(), target);
    expect(Directory(alias.path).existsSync(), isTrue);
    expect(
      File(p.join(root.path, 'source/unshipped')).readAsStringSync(),
      'source file',
    );
  });

  if (Platform.isWindows) {
    test('preserves native extended-prefix dot-dot symbolic-link targets', () {
      final binary = fixture('bin/windows-x64/archway.exe');
      final assets = p.join(root.absolute.path, 'source', 'assets');
      Directory(p.join(assets, 'nested')).createSync();
      final plainTarget = '$assets\\nested\\..\\typescript\\fixture';
      final nativeTarget = '\\\\?\\$plainTarget';
      final source = Link(p.join(assets, 'native-link'));
      final kernel = DynamicLibrary.open('kernel32.dll');
      final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
      );
      final create = kernel
          .lookupFunction<
            Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('CreateSymbolicLinkW');
      using((arena) {
        final result = create(
          source.path.toNativeUtf16(allocator: arena),
          nativeTarget.toNativeUtf16(allocator: arena),
          2,
        );
        final code = result == 0 ? error() : 0;
        expect(result, isNot(0), reason: 'Native source creation: $code');
      });
      // Dart creation would normalize this before the copier ever saw it.
      expect(source.targetSync(), plainTarget);
      final destination = Directory(p.join(root.path, 'destination'));
      stageInstallation(binary, destination);
      expect(
        Link(p.join(destination.path, 'assets/native-link')).targetSync(),
        plainTarget,
      );
    });

    test(
      'dangling directory targets use the original default file-link behavior',
      () {
        final binary = fixture('bin/windows-x64/archway.exe');
        final directory = Directory(p.join(root.path, 'source/unshipped'))
          ..createSync();
        final target = '..${Platform.pathSeparator}unshipped';
        Link(p.join(root.path, 'source/assets/dangling')).createSync(target);
        directory.deleteSync();
        final destination = Directory(p.join(root.path, 'destination'));
        stageInstallation(binary, destination);
        final alias = Link(p.join(destination.path, 'assets/dangling'));
        expect(alias.targetSync(), target);
        Directory(p.join(destination.path, 'unshipped')).createSync();
        expect(Directory(alias.path).existsSync(), isFalse);
      },
    );

    test('copies junction contents into an ordinary owned directory', () async {
      final binary = fixture('bin/windows-x64/archway.exe');
      final outside = Directory(p.join(root.path, 'junction target'))
        ..createSync();
      final original = File(p.join(outside.path, 'value'))
        ..writeAsStringSync('kept');
      final junction = p.join(root.path, 'source/assets/junction');
      final result = await _run(Platform.environment['ComSpec']!, [
        '/d',
        '/c',
        'mklink',
        '/J',
        junction,
        outside.path,
      ]);
      expect(result.$1, 0, reason: '${result.$2} ${result.$3}');
      final destination = Directory(p.join(root.path, 'destination'));
      stageInstallation(binary, destination);
      final copied = p.join(destination.path, 'assets/junction');
      expect(
        FileSystemEntity.typeSync(copied, followLinks: false),
        FileSystemEntityType.directory,
      );
      final value = File(p.join(copied, 'value'));
      expect(value.readAsStringSync(), 'kept');
      value.writeAsStringSync('copied');
      expect(original.readAsStringSync(), 'kept');
    });
  }

  if (!Platform.isWindows) {
    test(
      'preserves POSIX executable modes and launches the copied binary',
      () async {
        final binary = fixture('bin/linux-x64/archway');
        File('/bin/sh').copySync(binary.path);
        final libc = DynamicLibrary.process();
        final chmod = Platform.isMacOS
            ? libc.lookupFunction<
                Int32 Function(Pointer<Utf8>, Uint16),
                int Function(Pointer<Utf8>, int)
              >('chmod')
            : libc.lookupFunction<
                Int32 Function(Pointer<Utf8>, Uint32),
                int Function(Pointer<Utf8>, int)
              >('chmod');
        final nativePath = binary.path.toNativeUtf8();
        try {
          expect(
            chmod(nativePath, 0x1ef),
            0,
          ); // 0757, including an umask-masked bit.
        } finally {
          malloc.free(nativePath);
        }
        final staged = stageInstallation(
          binary,
          Directory(p.join(root.path, 'destination')),
        );
        expect(staged.statSync().mode & 0xfff, 0x1ef);
        expect(await _run(staged.path, ['-c', 'exit 37']), (37, '', ''));
        expect(staged.readAsBytesSync(), binary.readAsBytesSync());
      },
    );
  }
}

Future<(int, String, String)> _run(String executable, List<String> args) async {
  final child = await Process.start(executable, args);
  final completion = Future.wait<Object?>([
    child.exitCode,
    child.stdout.transform(utf8.decoder).join(),
    child.stderr.transform(utf8.decoder).join(),
    child.stdin.close(),
  ]);
  try {
    final result = await completion.timeout(const Duration(seconds: 10));
    return (result[0] as int, result[1] as String, result[2] as String);
  } finally {
    child.kill(ProcessSignal.sigkill);
    await completion.timeout(const Duration(seconds: 2));
  }
}
