import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_acceptance.dart';
import '../tool/ci/native_acceptance_capture.dart';
import 'support/windows_process_pipes.dart';
import 'support/native_file_fixtures.dart';

void main() {
  test(
    'Windows stdin options reject unsupported hosts before launch',
    () async {
      final root = Directory.systemTemp.createTempSync('acceptance-stdin-');
      addTearDown(() => root.deleteSync(recursive: true));
      final input = File(p.join(root.resolveSymbolicLinksSync(), 'input'))
        ..writeAsStringSync('input');
      final output = File(p.join(root.path, 'output'))
          .openSync(mode: FileMode.write);
      addTearDown(output.closeSync);
      await expectLater(
        captureAcceptanceProcess(
          [Platform.resolvedExecutable, '--version'],
          root.path,
          Platform.environment,
          output,
          output,
          const Duration(seconds: 5),
          windowsStdinFile: input,
        ),
        throwsUnsupportedError,
      );
      await expectLater(
        executeSuite(
          'unsupported',
          [Platform.resolvedExecutable, '--version'],
          root.path,
          Platform.environment,
          root,
          windowsStdinFile: input,
        ),
        throwsUnsupportedError,
      );
      expect(
        File(p.join(root.path, 'unsupported.stdout.log')).readAsBytesSync(),
        isEmpty,
      );
    },
    skip: Platform.isWindows ? 'Non-Windows stdin host control.' : false,
  );
  test(
    'Windows file stdin preserves exact bytes and EOF through suite capture',
    () async {
      final root = Directory.systemTemp.createTempSync('acceptance-stdin-');
      addTearDown(() => root.deleteSync(recursive: true));
      final script = File(p.join(root.path, 'read.dart'))
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  await for (final bytes in stdin) { stdout.add(bytes); }
  await stdout.flush();
  stderr.write('EOF'); await stderr.flush();
}
''');
      final input = File(p.join(root.resolveSymbolicLinksSync(), 'input'))
        ..writeAsBytesSync(
          List<int>.generate(200000, (i) => i % 256),
          flush: true,
        );
      for (final supplied in [false, true]) {
        final name = supplied ? 'file' : 'empty';
        final proof = await executeSuite(
          name,
          [
            Platform.resolvedExecutable,
            '--suppress-analytics',
            'run',
            script.path,
          ],
          root.path,
          Platform.environment,
          root,
          timeout: const Duration(seconds: 30),
          windowsStdinFile: supplied ? input : null,
        );
        expect(proof['exit_code'], 0);
        expect(
          File(p.join(root.path, '${name}.stdout.log')).readAsBytesSync(),
          supplied ? input.readAsBytesSync() : isEmpty,
        );
        expect(
          File(p.join(root.path, '${name}.stderr.log')).readAsStringSync(),
          'EOF',
        );
      }
      // Closing an unspawned owner also consumes the opened stdin handle.
      final pipes = WindowsProcessPipes(stdinFile: input);
      pipes.close();
      pipes.close();
      input.deleteSync();
      expect(input.existsSync(), isFalse);
    },
    skip: !Platform.isWindows ? 'Native Windows file stdin control.' : false,
  );

  test('Windows file stdin rejects invalid inputs and releases failed spawn handles', () async {
    final root = Directory.systemTemp.createTempSync('acceptance-stdin-');
    addTearDown(() => root.deleteSync(recursive: true));
    final input = File(p.join(root.resolveSymbolicLinksSync(), 'input'))
      ..writeAsStringSync('input');
    final link = Link(p.join(root.path, 'input-link'))..createSync(input.path);
    expect(
      () => WindowsProcessPipes(stdinFile: File(root.path)),
      throwsA(isA<OSError>()),
    );
    expect(
      () => WindowsProcessPipes(stdinFile: File(link.path)),
      throwsArgumentError,
    );
    expect(
      () => WindowsProcessPipes(stdinFile: File(p.join(root.path, 'missing'))),
      throwsA(isA<FileSystemException>()),
    );
    link.deleteSync();
    final lock = ExclusiveWindowsFileLock(input.path);
    try {
      expect(
        () => WindowsProcessPipes(stdinFile: input),
        throwsA(anyOf(isA<OSError>(), isA<FileSystemException>())),
      );
    } finally {
      lock.close();
    }
    await expectLater(
      executeSuite(
        'spawn-failure',
        [p.join(root.path, 'missing.exe')],
        root.path,
        Platform.environment,
        root,
        windowsStdinFile: input,
      ),
      throwsA(isA<OSError>()),
    );
    input.deleteSync(); // A leaked non-delete-sharing parent handle prevents this.
    expect(input.existsSync(), isFalse);
    expect(
      File(p.join(root.path, 'spawn-failure.stdout.log')).readAsBytesSync(),
      isEmpty,
    );
  }, skip: !Platform.isWindows ? 'Native Windows file stdin control.' : false);

  test(
    'Windows file stdin retains the restricted inherited handle list',
    () async {
      final api = DynamicLibrary.open('kernel32.dll');
      final create = api
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Int32, Int32, Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>, int, int, Pointer<Void>)
          >('CreateEventW');
      final wait = api
          .lookupFunction<
            Uint32 Function(Pointer<Void>, Uint32),
            int Function(Pointer<Void>, int)
          >('WaitForSingleObject');
      final close = api
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('CloseHandle');
      final security = calloc<Uint8>(24);
      security.cast<Uint32>().value = 24;
      (security + 16).cast<Int32>().value = 1;
      final sentinel = create(security.cast(), 1, 0, nullptr);
      calloc.free(security);
      expect(sentinel, isNot(nullptr));
      addTearDown(() => expect(close(sentinel), isNot(0)));
      final root = Directory.systemTemp.createTempSync(
        'acceptance-inheritance-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final input = File(p.join(root.resolveSymbolicLinksSync(), 'input'))
        ..writeAsStringSync('exact input');
      final script = File(p.join(root.path, 'read.dart'))
        ..writeAsStringSync('''
import 'dart:ffi';
import 'dart:io';
Future<void> main(List<String> args) async {
  final set = DynamicLibrary.open('kernel32.dll').lookupFunction<
    Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('SetEvent');
  set(Pointer<Void>.fromAddress(int.parse(args.single)));
  await for (final bytes in stdin) { stdout.add(bytes); }
  await stdout.flush();
}
''');
      await executeSuite(
        'restricted',
        [
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'run',
          script.path,
          sentinel.address.toString(),
        ],
        root.path,
        Platform.environment,
        root,
        windowsStdinFile: input,
      );
      expect(
        File(p.join(root.path, 'restricted.stdout.log')).readAsStringSync(),
        'exact input',
      );
      expect(wait(sentinel, 0), 258);
    },
    skip: !Platform.isWindows ? 'Native Windows file stdin control.' : false,
  );
}
