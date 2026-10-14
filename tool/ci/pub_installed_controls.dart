// Retained pub-only init failure contract through the actual installed route.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../npm/installed_assets.dart';
import '../validation/json_values.dart';

Future<Map<String, Object?>> exercisePubMissingBridgeInit(
  NpmInstalledControls controls,
) async {
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
  final saved = File('${bridge.path}.pub-init-saved');
  controls.require(
    FileSystemEntity.typeSync(saved.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Pub bridge backup already exists',
  );
  final root = controls.project.parent.createTempSync(
    'missing bridge init café-',
  );
  final before = controls.snapshot();
  var moved = false;
  try {
    bridge.renameSync(saved.path);
    moved = true;
    final result = await controls.capture([
      '--root',
      root.path,
      'init',
      '--template',
      'mixed',
    ], expectedExit: 2);
    controls.require(
      result.stderr.isEmpty &&
          result.stdout.isNotEmpty &&
          result.stdout.last == 10 &&
          result.stdout.where((byte) => byte == 10).length == 1,
      'Unavailable pub init must emit one stdout JSON line',
    );
    final value = jsonDecode(utf8.decode(result.stdout));
    controls.require(
      value['command'] == 'init' &&
          value['exit_code'] == 2 &&
          value['status'] == 'error' &&
          sameJson(
            (value['diagnostics'] as List).map((d) => d['code']).toList(),
            ['INIT_UNAVAILABLE'],
          ),
      'Missing bridge did not report INIT_UNAVAILABLE',
    );
    controls.require(root.listSync().isEmpty, 'Unavailable init created files');
  } finally {
    if (moved) saved.renameSync(bridge.path);
    root.deleteSync(recursive: true);
    controls.unchanged(before);
  }
  return {
    'case': 'missing-bridge-init',
    'invocation': 'installed-route',
    'exit': 2,
    'error': 'INIT_UNAVAILABLE',
  };
}
