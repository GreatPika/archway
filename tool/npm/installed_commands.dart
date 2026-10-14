// Compare the caller-bound installed route with its selected native payload.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import 'installed_assets.dart';

Future<List<Map<String, Object?>>> exerciseInstalledCommands(
  NpmInstalledControls controls,
) async {
  final cases = <Map<String, Object?>>[];
  late List<int> mermaid;
  for (final (name, arguments, code) in [
    ('validate-native-parity', ['validate'], 0),
    ('node-native-parity', ['node'], 0),
    ('export-native-parity', ['export', '--format', 'mermaid'], 0),
    (
      'literal-argv-native-parity',
      ['unknown; \$(touch should-not-exist) & café'],
      64,
    ),
  ]) {
    final before = controls.snapshot();
    final invocation = ['--root', controls.project.path, ...arguments];
    final native = await controls.capture(
      invocation,
      native: true,
      expectedExit: code,
    );
    final wrapped = await controls.capture(invocation, expectedExit: code);
    controls.require(
      wrapped.exitCode == native.exitCode &&
          sameJson(wrapped.stdout, native.stdout) &&
          sameJson(wrapped.stderr, native.stderr),
      'Installed route changed core argv/streams/exit',
    );
    controls.unchanged(before);
    controls.require(
      FileSystemEntity.typeSync(
            p.join(controls.cwd.path, 'should-not-exist'),
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound,
      'Literal command argument executed as shell code',
    );
    if (name == 'export-native-parity') mermaid = native.stdout;
    cases.add({
      'case': name,
      'arguments': arguments,
      'exit': code,
      'native_parity': true,
    });
  }

  final bridge = File(
    p.join(
      controls.payload.path,
      'native',
      controls.target,
      {
        'linux-x64': 'libarchway_io.so',
        'macos-arm64': 'libarchway_io.dylib',
        'windows-x64': 'archway_io.dll',
      }[controls.target]!,
    ),
  );
  final saved = File('${bridge.path}.control-saved');
  final output = File(p.join(controls.project.path, 'bridge output café.mmd'));
  for (final file in [saved, output]) {
    controls.require(
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Command control path already exists: ${file.path}',
    );
  }
  final before = controls.snapshot();
  bridge.renameSync(saved.path);
  try {
    final valid = await controls.capture([
      '--root',
      controls.project.path,
      'validate',
    ]);
    final validation = jsonDecode(utf8.decode(valid.stdout));
    controls.require(
      valid.stderr.isEmpty &&
          validation['command'] == 'validate' &&
          validation['exit_code'] == 0 &&
          validation['status'] == 'ok',
      'Policy validation unexpectedly requires the native bridge',
    );
    final failed = await controls.capture([
      '--root',
      controls.project.path,
      'export',
      '--format',
      'mermaid',
      '--out',
      p.basename(output.path),
    ], expectedExit: 2);
    controls.require(
      failed.stdout.isEmpty &&
          failed.stderr.isNotEmpty &&
          failed.stderr.last == 10 &&
          failed.stderr.where((byte) => byte == 10).length == 1,
      'Missing bridge must return one stderr-only export diagnostic',
    );
    final failure = jsonDecode(utf8.decode(failed.stderr));
    controls.require(
      failure['command'] == 'export' &&
          failure['exit_code'] == 2 &&
          failure['status'] == 'error' &&
          sameJson(
            (failure['diagnostics'] as List).map((d) => d['code']).toList(),
            ['EXPORT_WRITE_FAILED'],
          ),
      'Missing bridge did not report EXPORT_WRITE_FAILED',
    );
    controls.require(
      FileSystemEntity.typeSync(output.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Missing bridge must not create output',
    );
    cases.addAll([
      {'case': 'missing-bridge-validate', 'exit': 0},
      {
        'case': 'missing-bridge-export',
        'exit': 2,
        'error': 'EXPORT_WRITE_FAILED',
      },
    ]);
  } finally {
    saved.renameSync(bridge.path);
    controls.unchanged(before);
  }
  try {
    final restored = await controls.capture([
      '--root',
      controls.project.path,
      'export',
      '--format',
      'mermaid',
      '--out',
      p.basename(output.path),
    ]);
    controls.require(
      restored.stdout.isEmpty &&
          restored.stderr.isEmpty &&
          sameJson(output.readAsBytesSync(), mermaid),
      'Restored bridge export differs from native stdout bytes',
    );
    cases.add({'case': 'restored-bridge-export', 'exit': 0});
  } finally {
    if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      output.deleteSync();
    }
    controls.unchanged(before);
  }
  return cases;
}
