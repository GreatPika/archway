import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/installed_command_recorder.dart';
import '../tool/npm/installed_assets.dart';
import '../tool/npm/installed_commands.dart';
import 'support/native_process_support.dart';

void main() {
  for (final alteredArguments in [false, true]) {
    test(
      alteredArguments
          ? 'command controls reject changed installed route arguments'
          : 'command controls restore the bridge when the installed route throws',
      () async {
        final base = Directory(
          Directory.systemTemp
              .createTempSync('npm command controls ')
              .resolveSymbolicLinksSync(),
        );
        addTearDown(() => base.deleteSync(recursive: true));
        Directory directory(String name) =>
            Directory(p.join(base.path, name))..createSync(recursive: true);
        final payload = directory('separate native payload');
        final target = nativeTarget().target;
        final binary = File(
          p.join(
            payload.path,
            'bin',
            target,
            Platform.isWindows ? 'archway.exe' : 'archway',
          ),
        )..parent.createSync(recursive: true);
        final built = await runNativeProcess([
          Platform.resolvedExecutable,
          'compile',
          'exe',
          p.absolute('test/support/npm_command_control_child.dart'),
          '-o',
          binary.path,
        ], timeout: const Duration(seconds: 90));
        expect(built.exitCode, 0, reason: utf8.decode(built.stderr));
        final bridge = File(
          p.join(
            payload.path,
            'native',
            target,
            {
              'linux-x64': 'libarchway_io.so',
              'macos-arm64': 'libarchway_io.dylib',
              'windows-x64': 'archway_io.dll',
            }[target]!,
          ),
        )..parent.createSync(recursive: true);
        const original = [0, 1, 128, 255, 10];
        bridge.writeAsBytesSync(original);
        final failure = StateError('installed route interrupted');
        var interrupted = false;
        final controls = NpmInstalledControls(
          executable: File(p.join(base.path, 'logical npm shim')),
          command: (args) {
            if (!bridge.existsSync()) {
              interrupted = true;
              throw failure;
            }
            return [
              binary.path,
              ...args.skip(1),
              if (alteredArguments) 'unexpected-forwarded-argument',
            ];
          },
          project: directory('project'),
          cwd: directory('foreign'),
          wrapper: directory('wrapper'),
          payload: payload,
          target: target,
          environment: Platform.environment,
          recorder: InstalledCommandRecorder(output: directory('receipts')),
        );
        final before = controls.snapshot();
        await expectLater(
          exerciseInstalledCommands(controls),
          throwsA(
            alteredArguments
                ? isA<StateError>().having(
                    (error) => error.message,
                    'reason',
                    'Installed route changed core argv/streams/exit',
                  )
                : same(failure),
          ),
        );
        expect(
          interrupted,
          !alteredArguments,
          reason: 'Changed route arguments must fail before the bridge control',
        );
        expect(bridge.readAsBytesSync(), original);
        expect(controls.snapshot(), before);
      },
    );
  }
}
