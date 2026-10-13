import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archway/src/bootstrap/bootstrap.dart';
import 'package:archway/src/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  late void Function() clobberNativeError;
  if (Platform.isWindows) {
    final setLastError = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Void Function(Uint32), void Function(int)>('SetLastError');
    clobberNativeError = () => setLastError(22);
  } else {
    final errno =
        DynamicLibrary.open(
          Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        ).lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          Platform.isMacOS ? '__error' : '__errno_location',
        );
    clobberNativeError = () => errno().value = 22;
  }

  test(
    'native init conflict survives error-state clobber after the call',
    () async {
      final root = await temporaryRoot();
      final result = await runZoned(
        () => Bootstrap().initialize(root.path, 'mixed', false),
        zoneValues: {
          #archwayNativeAfterCall: clobberNativeError,
          #archwayBootstrapFault: (String stage, String path) {
            if (stage == 'beforeCreate') {
              File('${root.path}/$path').writeAsStringSync('other writer');
            }
          },
        },
      );
      expect(result.conflictingPaths, [
        'architecture.yaml',
      ], reason: result.diagnostics.map((d) => d.message).join('\n'));
      expect(result.createdPaths, isEmpty);
      expect(
        await File('${root.path}/architecture.yaml').readAsString(),
        'other writer',
      );
    },
  );

  test(
    'native missing residual survives error-state clobber after the call',
    () async {
      final root = await temporaryRoot();
      final result = await runZoned(
        () => Bootstrap().initialize(root.path, 'mixed', false),
        zoneValues: {
          #archwayNativeAfterCall: clobberNativeError,
          #archwayBootstrapFault: (String stage, String name) {
            if (stage == 'beforeCreate' && name == 'ARCHITECTURE_AGENT.md') {
              File('${root.path}/architecture.yaml').deleteSync();
              throw const FileSystemException('Injected second create failure');
            }
          },
        },
      );
      expect(result.outcome, 'rolled_back');
      expect(result.createdPaths, ['architecture.yaml']);
      expect(result.residualPaths, isEmpty);
    },
  );

  test(
    'native export conflict survives error-state clobber after the call',
    () async {
      final root = await temporaryRoot();
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final output = File('${root.path}/graph.mmd');
      await output.writeAsString('keep this');
      final out = StringBuffer();
      final err = StringBuffer();
      final exit = await runZoned(
        () => CLI().run([
          '--root',
          root.path,
          'export',
          '--format',
          'mermaid',
          '--out',
          'graph.mmd',
        ], CliStreams(out, err)),
        zoneValues: {#archwayNativeAfterCall: clobberNativeError},
      );
      expect(exit, 2);
      expect(out.toString(), '');
      expect(
        jsonDecode(err.toString())['diagnostics'].last['code'],
        'EXPORT_TARGET_EXISTS',
      );
      expect(await output.readAsString(), 'keep this');
    },
  );
}

Future<Directory> temporaryRoot() async {
  final root = await Directory.systemTemp.createTemp('archway-native-error-');
  addTearDown(() => root.delete(recursive: true));
  return root;
}
