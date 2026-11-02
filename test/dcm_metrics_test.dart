import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _clean = '✔ no metric violations found!';
const _limit =
    'Unable to show 99 found issues as the analyzed lines of code '
    'exceed your plan limit.';

void main() {
  _splitTests();
  _violationTest();
  _failureTests();
  _processTests();
  _inheritedPipeTest();
  _inventoryTests();
  _emptyInventoryTest();
  test('reports a complete clean run without changing sources', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    fixture.respond('.', _clean);

    final result = await fixture.run();

    expect(result.exitCode, 0);
    expect(fixture.summary()['complete'], isTrue);
    expect(fixture.summary()['status'], 'clean');
    expect(File('${fixture.root.path}/lib/a.dart').readAsStringSync(), '// a');
  });
}

void _splitTests() {
  test(
    'splits repeatedly and includes new directories and root files',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.write('new area/deep/b.dart', '// b');
      fixture.write('root.dart', '// root');
      fixture.respond('.', _limit, code: 1);
      fixture.respond('lib', _limit, code: 1);
      fixture.respond('lib/a.dart', _clean);
      fixture.respond('new area', _clean);
      fixture.respond('root.dart', _clean);

      final result = await fixture.run();

      expect(result.exitCode, 0);
      expect(fixture.summary()['complete'], isTrue);
      expect(fixture.summary()['inventory'], [
        'lib/a.dart',
        'new area/deep/b.dart',
        'root.dart',
      ]);
      expect(result.stdout, contains('3 parts'));
    },
  );
}

void _violationTest() {
  test(
    'aggregates violations without counting rejected parent output',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.respond('.', _limit, code: 1);
      fixture.respond(
        'lib',
        '• lib/a.dart:1:1 Too complex.\nScanned files: 1',
        code: 2,
      );

      final result = await fixture.run();

      expect(result.exitCode, 1);
      expect(fixture.summary()['complete'], isTrue);
      expect(fixture.summary()['violations'], [
        '• lib/a.dart:1:1 Too complex.',
      ]);
    },
  );
}

void _failureTests() {
  for (final response in [
    (text: _limit, code: 1),
    (text: 'License expired', code: 1),
    (text: 'Unexpected output', code: 0),
    (text: 'Config errors:\n$_clean', code: 0),
    (
      text:
          '$_clean\nAll analyzed contexts were skipped '
          'as they have no enabled metrics',
      code: 0,
    ),
    (text: _clean, code: 9),
  ]) {
    test('never reports clean for ${response.text}', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.respond('.', _limit, code: 1);
      fixture.respond('lib', _limit, code: 1);
      fixture.respond('lib/a.dart', response.text, code: response.code);

      final result = await fixture.run();

      expect(result.exitCode, 2);
      expect(fixture.summary()['complete'], isFalse);
      expect(fixture.summary()['status'], 'incomplete');
    });
  }
}

void _processTests() {
  test('missing executable produces an incomplete report', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);

    final result = await fixture.run(
      extra: ['--dcm=${fixture.directory.path}/missing-command'],
    );

    expect(result.exitCode, 2);
    expect(fixture.summary()['complete'], isFalse);
  });
}

void _inventoryTests() {
  test(
    'includes tracked and untracked Dart files but not ignored output',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.write('.gitignore', 'ignored/\n');
      fixture.write('ignored/generated.dart', '// generated');
      fixture.write('tool/new.dart', '// new');
      final tracked = await Process.run('git', [
        'add',
        'lib/a.dart',
      ], workingDirectory: fixture.root.path);
      expect(tracked.exitCode, 0);
      fixture.respond('.', _clean);

      final result = await fixture.run();

      expect(result.exitCode, 0);
      expect(fixture.summary()['inventory'], ['lib/a.dart', 'tool/new.dart']);
    },
  );
}

void _emptyInventoryTest() {
  test('empty inventory cannot produce a green report', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    File('${fixture.root.path}/lib/a.dart').deleteSync();

    final result = await fixture.run();

    expect(result.exitCode, 2);
    expect(result.stderr, contains('No Dart files found'));
    expect(result.stdout, isNot(contains('Report:')));
  });
}

void _inheritedPipeTest() {
  test('timeout also bounds pipes retained by a wrapper child', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    fixture.respond('.', 'PIPE_HOLD');

    final result = await fixture
        .run(extra: ['--timeout-seconds=1'])
        .timeout(const Duration(seconds: 4));

    expect(result.exitCode, 2);
    expect(fixture.summary()['complete'], isFalse);
  });
}

class _Fixture {
  _Fixture(this.directory, this.root, this.executable);

  final Directory directory;
  final Directory root;
  final File executable;
  final responses = <String, Object>{};
  String output = '';

  static Future<_Fixture> create() async {
    final directory = Directory.systemTemp.createTempSync('metrics-test-');
    final root = Directory('${directory.path}/repo with spaces')..createSync();
    final result = await Process.run('git', ['init', '-q', root.path]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
    final executable = File('${directory.path}/fake_dcm.dart')
      ..writeAsStringSync(_fakeDcm);
    final fixture = _Fixture(directory, root, executable);
    fixture.write('lib/a.dart', '// a');
    return fixture;
  }

  void write(String path, String contents) {
    final file = File('${root.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  void respond(String scope, String text, {int code = 0}) {
    responses[scope] = {'text': text, 'code': code};
  }

  Future<ProcessResult> run({List<String> extra = const []}) async {
    write('responses.json', jsonEncode(responses));
    final script = File('tool/dcm_metrics/check_metrics.dart').absolute.path;
    final result = await Process.run(Platform.resolvedExecutable, [
      script,
      '--root=${root.path}',
      '--dcm=${executable.path}',
      ...extra,
    ]);
    final match = RegExp(
      r'^Report: (.+)$',
      multiLine: true,
    ).firstMatch(result.stdout as String);
    output = match?.group(1) ?? '';
    return result;
  }

  Map<String, dynamic> summary() =>
      jsonDecode(File('$output/summary.json').readAsStringSync())
          as Map<String, dynamic>;

  void dispose() {
    directory.deleteSync(recursive: true);
    if (output.isNotEmpty) Directory(output).deleteSync(recursive: true);
  }
}

const _fakeDcm = r'''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (args.first == '--hold') {
    await Future<void>.delayed(const Duration(seconds: 5));
    return;
  }
  final responses = jsonDecode(File('responses.json').readAsStringSync()) as Map;
  final response = responses[args[1]] as Map?;
  if (!args.contains('--fatal-level=high') || response == null) {
    stderr.writeln('Unexpected DCM invocation: $args');
    exitCode = 9;
    return;
  }
  if (response['text'] == 'SLEEP') {
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  if (response['text'] == 'PIPE_HOLD') {
    await Process.start(Platform.resolvedExecutable,
        [Platform.script.toFilePath(), '--hold'],
        mode: ProcessStartMode.inheritStdio);
  }
  stdout.writeln(response['text']);
  exitCode = response['code'] as int;
}
''';
