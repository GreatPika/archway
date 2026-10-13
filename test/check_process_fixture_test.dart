import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'check_process_smoke.dart' show wildcardTargetUri, statMismatchHelper;
import 'support/native_process_support.dart';

void main() {
  test(
    'stat mismatch injection matches path spelling once and forwards I/O',
    () async {
      final node = Platform.environment['ARCHWAY_TEST_NODE'];
      if (node == null)
        throw StateError('ARCHWAY_TEST_NODE must name pinned Node');
      for (final (style, root, calls) in [
        (
          'win32',
          r'C:\project with spaces\café',
          [
            r'C:\project with spaces\café\src\core\private.ts',
            'C:/project with spaces/café/src/core/private.ts',
          ],
        ),
        (
          'win32',
          r'\\server\share\project',
          [
            r'\\server\share\project\src\core\private.ts',
            '//server/share/project/src/core/private.ts',
          ],
        ),
        (
          'posix',
          '/project with spaces/café',
          ['/project with spaces/café/src/core/private.ts'],
        ),
      ]) {
        final context = p.Context(
          style: style == 'win32' ? p.Style.windows : p.Style.posix,
        );
        final source = context.join(root, 'src/core/private.ts');
        final directory = context.join(root, 'src/core');
        for (final call in calls) {
          final result = await runNativeProcess([
            node,
            '-e',
            '''
const assert=require('node:assert/strict'),vm=require('node:vm');
const source=${jsonEncode(statMismatchHelper(source, directory))};
const target=${jsonEncode(call)},directory=${jsonEncode(directory)};
const calls=[],options={throwIfNoEntry:false};
const fs={statSync:(file,...args)=>{calls.push([file,...args]);return file;}};
let loaded=false;
vm.runInNewContext(source,{require:name=>{
  if(name==='node:fs')return fs;
  if(name==='node:path')return require('node:path')[${jsonEncode(style)}];
  assert.equal(name,'./real-helper.cjs');loaded=true;
}});
assert.equal(loaded,true);
assert.equal(fs.statSync(target+'.other',options),target+'.other');
assert.equal(fs.statSync(target,options),directory);
assert.equal(fs.statSync(target,options),target);
assert.deepEqual(calls,[[target+'.other',options],[directory,options],[target,options]]);
''',
          ], timeout: const Duration(seconds: 15));
          expect(result.exitCode, 0, reason: utf8.decode(result.stderr));
        }
      }
    },
  );

  test(
    'malformed helper target retains literal wildcard on all path styles',
    () {
      expect(
        () => Uri.file(r'C:\project\src\core\bad*.ts', windows: true),
        throwsArgumentError,
      );
      for (final (directory, expected) in [
        (
          Uri.directory(r'C:\project with spaces\café\src\core', windows: true),
          'file:///C:/project%20with%20spaces/caf%C3%A9/src/core/bad*.ts',
        ),
        (
          Uri.directory(
            r'\\server\share\project with spaces\src\core',
            windows: true,
          ),
          'file://server/share/project%20with%20spaces/src/core/bad*.ts',
        ),
        (
          Uri.directory('/project with spaces/café/src/core', windows: false),
          'file:///project%20with%20spaces/caf%C3%A9/src/core/bad*.ts',
        ),
      ]) {
        expect(wildcardTargetUri(directory), expected);
        expect(
          Uri.parse(wildcardTargetUri(directory)).pathSegments.last,
          'bad*.ts',
        );
      }
    },
  );
}
