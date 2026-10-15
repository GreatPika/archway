import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/npm/installed_assets.dart';
import '../tool/npm/installed_termination.dart';
import 'support/native_process_support.dart';

void main() {
  for (final malformed in [false, true]) {
    test(
      'termination restores bytes and created markers after ${malformed ? 'malformed readiness' : 'pre-barrier failure'}',
      () async {
        final base = Directory(
          Directory.systemTemp
              .createTempSync('npm termination ')
              .resolveSymbolicLinksSync(),
        );
        addTearDown(() => base.deleteSync(recursive: true));
        Directory dir(String name) =>
            Directory(p.join(base.path, name))..createSync(recursive: true);
        final payload = dir('payload');
        final helper =
            File(p.join(payload.path, 'assets/typescript/helper.cjs'))
              ..parent.createSync(recursive: true)
              ..writeAsBytesSync([0, 128, 255]);
        final controls = NpmInstalledControls(
          executable: File(Platform.resolvedExecutable),
          command: (_) => malformed
              ? [
                  Platform.resolvedExecutable,
                  '--suppress-analytics',
                  'run',
                  p.absolute('test/support/termination_failure_child.dart'),
                  base.path,
                ]
              : [Platform.resolvedExecutable, '--version'],
          project: dir('project'),
          cwd: dir('foreign'),
          wrapper: dir('wrapper'),
          payload: payload,
          target: nativeTarget().target,
          environment: Platform.environment,
          recorder: InstalledCommandRecorder(output: dir('evidence')),
        );
        final before = controls.snapshot();
        for (var phase = 0; phase < 2; phase++) {
          await expectLater(
            exerciseInstalledTermination(
              controls,
              node: File(Platform.resolvedExecutable),
            ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'failure',
                contains(
                  malformed ? 'Invalid helper-ready' : 'helper-ready barrier',
                ),
              ),
            ),
          );
        }
        final evidence = controls.recorder.output
            .listSync()
            .whereType<Directory>()
            .toList();
        expect(evidence, hasLength(2));
        expect(
          evidence.every(
            (directory) => directory.listSync().whereType<File>().length == 3,
          ),
          isTrue,
        );
        expect(helper.readAsBytesSync(), [0, 128, 255]);
        for (final directory in evidence) {
          final record = directory.listSync().whereType<File>().singleWhere(
            (file) => file.path.endsWith('.json'),
          );
          final proof = jsonDecode(record.readAsStringSync());
          for (final stream in ['stdout', 'stderr']) {
            final bytes = File('${p.withoutExtension(record.path)}.$stream.log')
                .readAsBytesSync();
            expect(proof['${stream}_sha256'], sha256.convert(bytes).toString());
          }
        }
        controls.unchanged(before);
        expect(
          File(p.join(base.path, 'npm termination ready.json')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(base.path, 'npm termination ready.pending')).existsSync(),
          isFalse,
        );
      },
    );
  }
}
