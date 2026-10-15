// Synthetic evidence checks the reader, never installed process correctness.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_npm_termination_evidence.dart';
import '../tool/ci/release_installed_output_receipts.dart';
import 'npm_termination_receipt_fixtures.dart';

void main() {
  late Directory root, directory;
  late Map<String, dynamic> phase;
  const prefix = [
    '/node',
    '/npm-cli.js',
    'exec',
    '--offline',
    '--yes',
    '--package=/candidate.tgz',
    '--',
    'archway',
  ];
  const project = '/project',
      shim = '/cache/node_modules/.bin/archway',
      native = '/payload/bin/linux-x64/archway';
  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('termination-reader-')
          .resolveSymbolicLinksSync(),
    );
    directory = Directory(p.join(root.path, 'termination-owned'))..createSync();
    final summary = terminationFixture(
      'linux-x64',
      'cache',
    )['termination_control'];
    phase = {
      'termination_directory': 'termination-owned',
      'termination': summary,
      'payload': '/payload',
      'project': project,
      'shim': shim,
    };
    var index = 0;
    for (final event in ['SIGINT', 'SIGTERM', 'SIGHUP']) {
      for (final role in [
        'route',
        'native',
        'outer',
        if (event == 'SIGINT') 'group',
      ]) {
        final name = '${event.toLowerCase()}-$role';
        final code = event == 'SIGINT'
            ? 2
            : event == 'SIGTERM'
            ? -15
            : -1;
        final cancelled = jsonDecode(
          File('contracts/json/fixtures/check-tool-error.json')
              .readAsStringSync(),
        ) as Map;
        cancelled['tool_versions']['archway'] = '2.3.4';
        cancelled['resolved_root'] = project;
        cancelled['status'] = 'incomplete';
        cancelled['payload']['tool_errors'][0]['code'] = 'INSPECTION_CANCELLED';
        cancelled['diagnostics'] = cancelled['payload']['tool_errors'];
        final output = (event == 'SIGINT' && role != 'outer')
            ? '${jsonEncode(cancelled)}\n'
            : '';
        File(p.join(directory.path, '$name.stdout.log'))
            .writeAsStringSync(output);
        File(p.join(directory.path, '$name.stderr.log')).writeAsStringSync('');
        File(p.join(directory.path, '$name.json')).writeAsStringSync(
          jsonEncode({
            'command': [
              if (role == 'native')
                native
              else if (role == 'route')
                shim
              else
                ...prefix,
              '--root',
              project,
              'check',
            ],
            'route': role,
            'stimulus': event,
            'exit': role == 'outer'
                ? null
                : role == 'group'
                ? -2
                : code,
            'pids': {'core': 100, 'helper': 101},
            'failure': null,
            'cleanup_failures': [],
            'observation': role == 'outer'
                ? summary['outer_npm_pid_observations']['cases'][index]['observation']
                : null,
            'stdout_sha256': sha256.convert(utf8.encode(output)).toString(),
            'stderr_sha256': sha256.convert([]).toString(),
          }),
        );
      }
      index++;
    }
  });
  tearDown(() => root.deleteSync(recursive: true));
  void inspect() => validateNpmTerminationEvidence(
    phase,
    root,
    target: 'linux-x64',
    route: 'cache',
    prefix: prefix,
    outputValidator: InstalledOutputValidator(Directory.current, '2.3.4'),
  );
  test('termination reader preserves actual outer group and cached-shim evidence split', () {
    inspect();
    final groupFile = File(p.join(directory.path, 'sigint-group.json'));
    final originalGroup = groupFile.readAsStringSync();
    final group = jsonDecode(originalGroup) as Map;
    group['exit'] = (group['exit'] as int).toDouble();
    groupFile.writeAsStringSync(jsonEncode(group));
    expect(
      inspect,
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'original integer exit',
          'Actual npm-exec group observation differs',
        ),
      ),
    );
    groupFile.writeAsStringSync(originalGroup);
    phase['termination']['outer_npm_pid_observations']['cases'][0]['status'] =
        'PASSED';
    expect(
      inspect,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('relabeled'),
        ),
      ),
    );
  });
  test(
    'termination reader binds source argv cleanup and original stream bytes',
    () {
      final file = File(p.join(directory.path, 'sigint-route.json'));
      final original = file.readAsStringSync();
      final value = jsonDecode(original) as Map;
      value['command'][0] = '/unrelated/archway';
      file.writeAsStringSync(jsonEncode(value));
      expect(
        inspect,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('command'),
          ),
        ),
      );
      file.writeAsStringSync(original);
      value['command'][0] = shim;
      value['cleanup_failures'] = ['unreaped child'];
      file.writeAsStringSync(jsonEncode(value));
      expect(
        inspect,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('cleanup'),
          ),
        ),
      );
      file.writeAsStringSync(original);
      File(p.join(directory.path, 'sigint-route.stdout.log'))
          .writeAsStringSync('changed');
      expect(
        inspect,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('hash differs'),
          ),
        ),
      );
    },
  );
  test('cancellation evidence requires full public schema beyond matching summaries', () {
    inspect();
    for (final role in ['native', 'route']) {
      final output = File(p.join(directory.path, 'sigint-$role.stdout.log'));
      final value = jsonDecode(output.readAsStringSync()) as Map;
      value.remove('tool_versions');
      output.writeAsStringSync('${jsonEncode(value)}\n');
      final record = File(p.join(directory.path, 'sigint-$role.json'));
      final metadata = jsonDecode(record.readAsStringSync()) as Map;
      metadata['stdout_sha256'] = sha256
          .convert(output.readAsBytesSync())
          .toString();
      record.writeAsStringSync(jsonEncode(metadata));
    }
    expect(
      inspect,
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'public output boundary',
          'Installed result schema/version/command/status differs',
        ),
      ),
    );
  });
}
