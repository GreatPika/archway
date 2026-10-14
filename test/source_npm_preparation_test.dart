import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/source_npm_preparation.dart';

void main() {
  test(
    'offline source npm command uses admitted Node and exact host package path',
    () {
      for (final windows in [false, true]) {
        final paths = p.Context(
          style: windows ? p.Style.windows : p.Style.posix,
        );
        final node = windows ? r'C:\node\node.exe' : '/node/bin/node';
        final root = windows ? r'C:\source café' : '/source café';
        expect(sourceNpmCommand(node, root, paths), [
          node,
          windows
              ? r'C:\node\node_modules\npm\bin\npm-cli.js'
              : '/node/lib/node_modules/npm/bin/npm-cli.js',
          'ci',
          '--prefix',
          windows ? r'C:\source café\tool\npm' : '/source café/tool/npm',
          '--offline',
          '--ignore-scripts',
          '--no-audit',
          '--no-fund',
        ]);
        expect(
          () => sourceNpmCommand('node', root, paths),
          throwsFormatException,
        );
        expect(
          () => sourceNpmCommand(node, 'source', paths),
          throwsFormatException,
        );
      }
    },
  );
  test('actual offline source preparation installs without executing package scripts', () async {
    final selected = await Process.run('node', ['-p', 'process.execPath']);
    expect(selected.exitCode, 0);
    final node = (selected.stdout as String).trim();
    final root = Directory.systemTemp.createTempSync('source npm café-');
    addTearDown(() => root.deleteSync(recursive: true));
    final package = Directory(p.join(root.path, 'tool', 'npm'))
      ..createSync(recursive: true);
    final metadata = {
      'name': 'offline-source-test',
      'version': '1.0.0',
      'scripts': {
        'install':
            'node -e "require(\'fs\').writeFileSync(\'EXECUTED\',\'bad\')"',
      },
    };
    File(p.join(package.path, 'package.json'))
        .writeAsStringSync(jsonEncode(metadata));
    final lock = File(p.join(package.path, 'package-lock.json'))
      ..writeAsStringSync(
        jsonEncode({
          'name': 'offline-source-test',
          'version': '1.0.0',
          'lockfileVersion': 3,
          'requires': true,
          'packages': {
            '': {...metadata, 'hasInstallScript': true},
          },
        }),
      );
    final original = lock.readAsStringSync();
    final command = sourceNpmCommand(node, root.path, p.context);
    final result = await Process.run(
      command.first,
      command.skip(1).toList(),
      workingDirectory: root.path,
      environment: {'npm_config_cache': p.join(root.path, 'empty-cache')},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(lock.readAsStringSync(), original);
    expect(File(p.join(package.path, 'EXECUTED')).existsSync(), isFalse);
  });
}
