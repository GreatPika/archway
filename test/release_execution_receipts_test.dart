import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_execution_receipts.dart';

void main() {
  late Directory directory;
  const command = ['/sdk/bin/dart', 'test', '--reporter=json'];
  late Map<String, Object?> receipt;
  void save() =>
      File(p.join(directory.path, 'source-tests.json'))
          .writeAsStringSync(jsonEncode(receipt));
  setUp(() {
    final temporary = Directory.systemTemp.createTempSync('execution-receipt-');
    directory = Directory(temporary.resolveSymbolicLinksSync());
    receipt = {
      'suite': 'source-tests',
      'command': command,
      'exit_code': 0,
      'timed_out': false,
      'elapsed_seconds': 0.25,
      'timeout_seconds': 600,
      'stdout': 'source-tests.stdout.log',
      'stderr': 'source-tests.stderr.log',
      'stdout_sha256': sha256
          .convert(utf8.encode('original output'))
          .toString(),
      'stderr_sha256': sha256.convert([]).toString(),
    };
    File(p.join(directory.path, 'source-tests.stdout.log'))
        .writeAsStringSync('original output');
    File(p.join(directory.path, 'source-tests.stderr.log'))
        .writeAsStringSync('');
    save();
  });
  tearDown(() => directory.deleteSync(recursive: true));
  test('successful execution binds both original streams and receipt', () {
    expect(
      validateExecution(
        receipt,
        command,
        directory,
        p.posix,
        suite: 'source-tests',
      ),
      {'stdout': utf8.encode('original output'), 'stderr': <int>[]},
    );
  });
  test('original JSON rejects duplicate decoded keys at any depth', () {
    for (final json in [
      '{"suite":"wrong","suite":"source-tests"}',
      r'{"nested":{"a":1,"\u0061":2}}',
      '[{"key":0,"key":0}]',
    ]) {
      File(p.join(directory.path, 'duplicate.json')).writeAsStringSync(json);
      expect(
        () => readRecord(File(p.join(directory.path, 'duplicate.json'))),
        throwsFormatException,
        reason: json,
      );
    }
  });

  for (final windows in [false, true]) {
    final paths = windows ? p.windows : p.posix;
    final expected = [
      windows ? r'C:\SDK\bin\dart.exe' : '/sdk/bin/dart',
      'test',
      '--reporter=json',
    ];
    test('${paths.style} independently rejects receipt corruptions', () {
      final mutations = <void Function(Map<String, Object?>)>[
        (r) => r['extra'] = true,
        (r) => r.remove('elapsed_seconds'),
        (r) => r['suite'] = 'wrong',
        (r) => r['exit_code'] = 1,
        (r) => r['exit_code'] = 0.0,
        (r) => r['exit_code'] = false,
        (r) => r['timed_out'] = true,
        (r) => r['timed_out'] = 0,
        (r) => r['timeout_seconds'] = 599,
        (r) => r['timeout_seconds'] = 600.0,
        (r) => r['elapsed_seconds'] = -1,
        (r) => r['elapsed_seconds'] = '0',
        (r) => r['elapsed_seconds'] = false,
        (r) => r['command'] = [],
        (r) => r['command'] = [false, ...expected.skip(1)],
        (r) => r['command'] = ['different', ...expected.skip(1)],
        (r) => r['command'] = [...expected, 'extra'],
        (r) => r['command'] = [expected[0], 'test'],
        (r) => r['command'] = [expected[0], 'TEST', '--reporter=json'],
        (r) => r['stdout'] = '../source-tests.stdout.log',
        (r) => r['stderr'] = '/source-tests.stderr.log',
        (r) => r['stdout_sha256'] = '0' * 64,
        (r) => r['stderr_sha256'] = 'A' * 64,
        (r) => r['stderr_sha256'] = false,
      ];
      final original = {...receipt, 'command': expected};
      for (var i = 0; i < mutations.length; i++) {
        receipt = {...original};
        mutations[i](receipt);
        save();
        expect(
          () => validateExecution(
            receipt,
            expected,
            directory,
            paths,
            suite: 'source-tests',
          ),
          throwsFormatException,
          reason: 'mutation $i',
        );
      }
    });
    test('${paths.style} permits only executable lexical equivalents', () {
      receipt['command'] = [
        windows ? 'c:/sdk/./bin//DART.EXE' : '/sdk/./bin//dart',
        ...expected.skip(1),
      ];
      save();
      expect(
        validateExecution(
          receipt,
          expected,
          directory,
          paths,
          suite: 'source-tests',
        )['stdout'],
        utf8.encode('original output'),
      );
      for (final executable in [
        windows ? r'C:\SDK\other\..\bin\dart.exe' : '/sdk/other/../bin/dart',
        windows ? r'D:\SDK\bin\dart.exe' : '/SDK/bin/dart',
      ]) {
        receipt['command'] = [executable, ...expected.skip(1)];
        save();
        expect(
          () => validateExecution(
            receipt,
            expected,
            directory,
            paths,
            suite: 'source-tests',
          ),
          throwsFormatException,
        );
      }
    });
  }
  test('POSIX exactly two leading slashes preserve a distinct root', () {
    for (final pair in [
      ('//sdk/bin/dart', '/sdk/bin/dart'),
      ('/sdk/bin/dart', '//sdk/bin/dart'),
    ]) {
      receipt['command'] = [pair.$1, ...command.skip(1)];
      save();
      expect(
        () => validateExecution(
          receipt,
          [pair.$2, ...command.skip(1)],
          directory,
          p.posix,
          suite: 'source-tests',
        ),
        throwsFormatException,
      );
    }
    for (final path in ['//sdk/bin/dart', '///sdk/bin/dart']) {
      receipt['command'] = [path, ...command.skip(1)];
      save();
      expect(
        validateExecution(
          receipt,
          [path.startsWith('///') ? '/sdk/bin/dart' : path, ...command.skip(1)],
          directory,
          p.posix,
          suite: 'source-tests',
        )['stdout'],
        utf8.encode('original output'),
      );
    }
  });
  test('shared evidence path identity is lexical and target aware', () {
    expect(sameEvidencePath('/sdk/other/../dart', '/sdk/dart', p.posix), false);
    expect(sameEvidencePath('//sdk/dart', '/sdk/dart', p.posix), false);
    expect(
      sameEvidencePath(
        r'C:\SDK\bin\dart.exe',
        'c:/sdk/bin/DART.EXE',
        p.windows,
      ),
      true,
    );
  });
  test('nonfinite elapsed values fail without JSON serialization', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      receipt['elapsed_seconds'] = value;
      expect(
        () => validateExecution(
          receipt,
          command,
          directory,
          p.posix,
          suite: 'source-tests',
        ),
        throwsFormatException,
      );
    }
  });
  test('original receipt mismatch and numeric type corruption fail', () {
    for (final change in [
      {'elapsed_seconds': 1},
      {'exit_code': 0.0},
      {'timeout_seconds': 600.0},
    ]) {
      File(p.join(directory.path, 'source-tests.json'))
          .writeAsStringSync(jsonEncode({...receipt, ...change}));
      expect(
        () => validateExecution(
          receipt,
          command,
          directory,
          p.posix,
          suite: 'source-tests',
        ),
        throwsFormatException,
      );
    }
  });
  test('unsafe suite names cannot select evidence outside fixed files', () {
    for (final name in [
      '../source-tests',
      '/source-tests',
      r'C:\source-tests',
      '.',
      '',
      'a/b',
      'a\\b',
      'source-tests\n',
    ]) {
      receipt['suite'] = name;
      expect(
        () => validateExecution(
          receipt,
          command,
          directory,
          p.posix,
          suite: name,
        ),
        throwsFormatException,
        reason: name,
      );
    }
  });
  test('both original stream tampering and duplicate receipt keys fail', () {
    for (final stream in ['stdout', 'stderr']) {
      final file = File(p.join(directory.path, 'source-tests.$stream.log'));
      final bytes = file.readAsBytesSync();
      file.writeAsStringSync('altered');
      expect(
        () => validateExecution(
          receipt,
          command,
          directory,
          p.posix,
          suite: 'source-tests',
        ),
        throwsFormatException,
      );
      file.writeAsBytesSync(bytes);
    }
    final encoded = jsonEncode(receipt);
    File(p.join(directory.path, 'source-tests.json'))
        .writeAsStringSync('{"exit_code":99,${encoded.substring(1)}');
    expect(
      () => validateExecution(
        receipt,
        command,
        directory,
        p.posix,
        suite: 'source-tests',
      ),
      throwsFormatException,
    );
  });

  test('JSON grammar, nesting, UTF-8 and two MiB bound fail closed', () {
    for (final text in [
      '',
      '{}{}',
      '{"a":1,}',
      '[1,]',
      '{a:1}',
      '{"a" 1}',
      '01',
      '+1',
      'NaN',
      '1e999',
      'true false',
      '"unescaped\nline"',
      r'"\x00"',
      '${'[' * 130}0${']' * 130}',
    ]) {
      expect(
        () => decodeEvidenceJson(text),
        throwsFormatException,
        reason: text,
      );
    }
    expect(
      decodeEvidenceJson(r'{"x":[null,true,false,-1,0.25,1e2,"\u0061"]}'),
      {
        'x': [null, true, false, -1, 0.25, 100.0, 'a'],
      },
    );
    final file = File(p.join(directory.path, 'record.json'));
    file.writeAsBytesSync([0xff]);
    expect(() => readRecord(file), throwsFormatException);
    file.writeAsStringSync('0${' ' * (2 * 1024 * 1024 - 1)}');
    expect(readRecord(file), 0);
    file.writeAsStringSync(' ', mode: FileMode.append);
    expect(() => readRecord(file), throwsFormatException);
    expect(
      () => decodeEvidenceJson('"${'é' * (1024 * 1024)}"'),
      throwsFormatException,
    );
  });
  test(
    'ordinary file bounds include empty files and exactly bounded bytes',
    () {
      final file = File(p.join(directory.path, 'bounded'))
        ..writeAsBytesSync([1, 2, 3]);
      expect(readOrdinaryBytes(file, limit: 3), [1, 2, 3]);
      expect(() => readOrdinaryBytes(file, limit: 2), throwsFormatException);
      final handle = file.openSync(mode: FileMode.write);
      try {
        handle.truncateSync(128 * 1024 * 1024 + 1);
      } finally {
        handle.closeSync();
      }
      expect(() => verifiedBytes(file, '0' * 64), throwsFormatException);
      file.writeAsBytesSync([]);
      expect(readOrdinaryBytes(file, limit: 0), isEmpty);
      expect(
        () => readOrdinaryBytes(File(directory.path)),
        throwsFormatException,
      );
      expect(
        () => readOrdinaryBytes(File(p.join(directory.path, 'missing'))),
        throwsFormatException,
      );
    },
  );
  test('nonordinary evidence and actual ancestor/file aliases fail', () {
    final original = File(p.join(directory.path, 'source-tests.stdout.log'));
    final saved = original.readAsBytesSync();
    original.deleteSync();
    Directory(original.path).createSync();
    expect(
      () => validateExecution(
        receipt,
        command,
        directory,
        p.posix,
        suite: 'source-tests',
      ),
      throwsFormatException,
    );
    Directory(original.path).deleteSync();
    original.writeAsBytesSync(saved);
    final alias = Link(p.join(directory.path, 'alias'));
    try {
      alias.createSync(directory.path);
    } on FileSystemException catch (error) {
      if (Platform.isWindows && error.osError?.errorCode == 1314) return;
      rethrow;
    }
    expect(
      () => validateExecution(
        receipt,
        command,
        Directory(alias.path),
        p.posix,
        suite: 'source-tests',
      ),
      throwsFormatException,
    );
    alias.deleteSync();
    for (final suffix in ['json', 'stdout.log', 'stderr.log']) {
      final file = File(p.join(directory.path, 'source-tests.$suffix'));
      final backup = file.renameSync('${file.path}.original');
      Link(file.path).createSync(backup.path);
      expect(
        () => validateExecution(
          receipt,
          command,
          directory,
          p.posix,
          suite: 'source-tests',
        ),
        throwsFormatException,
        reason: suffix,
      );
      Link(file.path).deleteSync();
      backup.renameSync(file.path);
    }
    if (!Platform.isWindows) {
      final fifo = p.join(directory.path, 'fifo');
      final result = Process.runSync('mkfifo', [fifo]);
      expect(result.exitCode, 0);
      expect(() => readOrdinaryBytes(File(fifo)), throwsFormatException);
    }
  });
}
