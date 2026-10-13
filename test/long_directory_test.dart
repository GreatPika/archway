import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'physical_paths_test.dart' show checkPhysical;

void main() {
  for (final explicit in [false, true]) {
    test(
      'long directory ${explicit ? "scope prefixes" : "descent"} retain corpus identity',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'archway-long-',
        );
        final root = Directory(await temporary.resolveSymbolicLinks());
        // Fixture creation/cleanup uses the OS extended spelling independently.
        String fixturePath(String path) => Platform.isWindows
            ? (path.startsWith(r'\\')
                  ? '\\\\?\\UNC\\${path.substring(2)}'
                  : '\\\\?\\$path')
            : path;
        addTearDown(
          () => Directory(fixturePath(root.path)).delete(recursive: true),
        );
        final relative = 'src/${'a' * 190}/${'b' * 190}/${'c' * 190}';
        final directory = p.joinAll([root.path, ...relative.split('/')]);
        expect(directory.length, greaterThan(260));
        await Directory(fixturePath(p.join(directory, 'nested')))
            .create(recursive: true);
        final paths = ['$relative/café.ts', '$relative/nested/other.ts'];
        const contents = 'export {};';
        for (final path in paths) {
          final file = File(
            fixturePath(p.joinAll([root.path, ...path.split('/')])),
          );
          await file.writeAsString(contents);
          expect(await file.readAsString(), contents);
        }
        await File(p.join(root.path, 'architecture.yaml'))
            .writeAsString('''version: 1
projects: []
scope: [${explicit ? '$relative/' : 'src/'}]
exclude: []
nodes: []
''');
        final report = await checkPhysical(root, 2);
        final payload = report['payload'];
        expect(
          (payload['coverage']['files'] as List).map((row) => row['path']),
          paths,
        );
        expect(
          (payload['unknowns'] as List).map((row) => row['code']),
          everyElement('ANALYSIS_CONTEXT_MISSING'),
        );
        expect(payload['tool_errors'], isEmpty);
        final identity = payload['input_identity'];
        expect(identity['rechecked'], true);
        expect(identity['changed_inputs'], isEmpty);
        expect(identity['aliases'], isEmpty);
        for (final path in paths) {
          expect(
            identity['inputs'],
            contains(
              allOf(
                containsPair('kind', 'source'),
                containsPair('location', {'kind': 'repository', 'path': path}),
                containsPair(
                  'hash',
                  'sha256:${sha256.convert(utf8.encode(contents))}',
                ),
              ),
            ),
          );
        }
        final alias = Link(fixturePath(p.join(directory, 'alias.ts')));
        await alias.create('café.ts');
        expect(await alias.target(), 'café.ts');
        final linked = await checkPhysical(root, 2);
        expect(
          (linked['payload']['coverage']['files'] as List).map(
            (row) => row['path'],
          ),
          paths,
        );
        expect(
          (linked['payload']['unknowns'] as List)
              .where((row) => row['code'] == 'SOURCE_SYMLINK')
              .map((row) => row['path']),
          ['$relative/alias.ts'],
        );
        expect(linked['payload']['input_identity']['rechecked'], true);
        expect(linked['payload']['input_identity']['changed_inputs'], isEmpty);
        expect(jsonEncode(report), isNot(contains(r'\\\\?\\')));
      },
    );
  }
}
