import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/installation_staging.dart';

void main() {
  final executableName = Platform.isWindows ? 'archway.exe' : 'archway';
  final executablePath = p.join('bin', executableName);
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('archway-staging-'));
  tearDown(() => root.deleteSync(recursive: true));

  File fixture(String relative) {
    final binary = File(p.join(root.path, 'source', relative));
    binary.parent.createSync(recursive: true);
    binary.writeAsStringSync('actual executable');
    for (final directory in ['lib/nested']) {
      final asset = File(p.join(root.path, 'source', directory, 'fixture'));
      asset.parent.createSync(recursive: true);
      asset.writeAsStringSync('asset');
    }
    return binary;
  }

  test('copies the SDK bundle layout for the current platform', () {
    final binary = fixture(executablePath);
    final destination = Directory(p.join(root.path, 'relocated café'));
    final staged = stageInstallation(binary, destination);
    expect(p.relative(staged.path, from: destination.path), executablePath);
    expect(staged.readAsBytesSync(), utf8.encode('actual executable'));
    expect(
      File(p.join(destination.path, 'lib/nested/fixture')).readAsBytesSync(),
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

  test('rejects the removed universal archive layout', () {
    final binary = fixture('bin/macos-universal/archway');
    final destination = Directory(p.join(root.path, 'destination'));
    expect(() => stageInstallation(binary, destination), throwsArgumentError);
    expect(destination.existsSync(), isFalse);
  });

  test('does not merge into pre-existing installation directories', () {
    final binary = fixture(executablePath);
    for (final directory in ['bin', 'lib']) {
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
    final binary = fixture(executablePath);
    final assets = Directory(p.join(root.path, 'source', 'lib'));
    final separator = Platform.pathSeparator;
    final targets = {
      'relative':
          '.${separator}nested$separator..${separator}nested'
          '${separator}fixture',
      'dangling': 'missing-target',
      'cycle': 'cycle',
      'directory': p.join(assets.path, 'nested'),
    };
    for (final entry in targets.entries) {
      Link(p.join(assets.path, entry.key)).createSync(entry.value);
    }
    final destination = Directory(p.join(root.path, 'destination'));
    stageInstallation(binary, destination);
    for (final entry in targets.entries) {
      final copied = Link(p.join(destination.path, 'lib', entry.key));
      expect(copied.existsSync(), isTrue);
      expect(copied.targetSync(), entry.value);
    }
    expect(
      File(p.join(destination.path, 'lib/relative')).readAsStringSync(),
      'asset',
    );
  });

  test('infers symbolic-link directory type at the destination', () {
    final binary = fixture(executablePath);
    File(p.join(root.path, 'source/unshipped'))
        .writeAsStringSync('source file');
    final target = '..${Platform.pathSeparator}unshipped';
    Link(p.join(root.path, 'source/lib/alias')).createSync(target);
    final destination = Directory(p.join(root.path, 'destination'))
      ..createSync();
    Directory(p.join(destination.path, 'unshipped')).createSync();
    stageInstallation(binary, destination);
    final alias = Link(p.join(destination.path, 'lib/alias'));
    expect(alias.targetSync(), target);
    expect(Directory(alias.path).existsSync(), isTrue);
    expect(
      File(p.join(root.path, 'source/unshipped')).readAsStringSync(),
      'source file',
    );
  });

  if (Platform.isWindows) {
    test('preserves native extended-prefix dot-dot symbolic-link targets', () {
      final binary = fixture(executablePath);
      final assets = p.join(root.absolute.path, 'source', 'lib');
      Directory(p.join(assets, 'nested')).createSync();
      final plainTarget = '$assets\\nested\\..\\nested\\fixture';
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
        Link(p.join(destination.path, 'lib/native-link')).targetSync(),
        plainTarget,
      );
    });

    test(
      'dangling directory targets use the original default file-link behavior',
      () {
        final binary = fixture(executablePath);
        final directory = Directory(p.join(root.path, 'source/unshipped'))
          ..createSync();
        final target = '..${Platform.pathSeparator}unshipped';
        Link(p.join(root.path, 'source/lib/dangling')).createSync(target);
        directory.deleteSync();
        final destination = Directory(p.join(root.path, 'destination'));
        stageInstallation(binary, destination);
        final alias = Link(p.join(destination.path, 'lib/dangling'));
        expect(alias.targetSync(), target);
        Directory(p.join(destination.path, 'unshipped')).createSync();
        expect(Directory(alias.path).existsSync(), isFalse);
      },
    );

    test('copies junction contents into an ordinary owned directory', () async {
      final binary = fixture(executablePath);
      final outside = Directory(p.join(root.path, 'junction target'))
        ..createSync();
      final original = File(p.join(outside.path, 'value'))
        ..writeAsStringSync('kept');
      final junction = p.join(root.path, 'source', 'lib', 'junction');
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
      final copied = p.join(destination.path, 'lib/junction');
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
        final binary = fixture(executablePath);
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
