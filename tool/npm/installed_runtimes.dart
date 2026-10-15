// Runtime provenance and core checks are reusable; npm launcher absence is separate.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../validation/json_values.dart';
import 'installed_assets.dart';

Map<String, String> _withPath(NpmInstalledControls controls, String path) => {
  for (final entry in controls.environment.entries)
    if (entry.key.toLowerCase() != 'path') entry.key: entry.value,
  'PATH': path,
};

/// Records actual runtime identity before asking the installed route to reject it.
Future<Map<String, Object?>> verifyInstalledWrongNode(
  NpmInstalledControls controls,
  File wrongNode,
) async {
  controls.require(
    FileSystemEntity.typeSync(wrongNode.path, followLinks: false) ==
            FileSystemEntityType.file &&
        wrongNode.resolveSymbolicLinksSync() == wrongNode.path,
    'Supply a canonical prepared genuine Node 24.19.0',
  );
  final version = await controls.recorder.capture(
    [
      wrongNode.path,
      '-p',
      'JSON.stringify([process.version,process.platform,process.arch])',
    ],
    workingDirectory: controls.cwd.path,
    environment: controls.environment,
    timeout: const Duration(seconds: 30),
  );
  final expected = [
    'v24.19.0',
    {
      'linux-x64': 'linux',
      'macos-arm64': 'darwin',
      'windows-x64': 'win32',
    }[controls.target],
    controls.target == 'macos-arm64' ? 'arm64' : 'x64',
  ];
  controls.require(
    version.stderr.isEmpty &&
        sameJson(jsonDecode(utf8.decode(version.stdout)), expected),
    'Wrong negative-control runtime: expected genuine Node 24.19.0 for ${controls.target}',
  );
  final before = controls.snapshot();
  final result = await controls.capture(
    ['--root', controls.project.path, 'check'],
    environment: _withPath(controls, wrongNode.parent.path),
    expectedExit: 2,
  );
  controls.incomplete(result, 'NODE_UNAVAILABLE');
  controls.unchanged(before);
  return {
    'wrong_node': {
      'version': '24.19.0',
      'platform': expected[1],
      'arch': expected[2],
      'executable_sha256': (await sha256.bind(wrongNode.openRead()).first)
          .toString(),
    },
    'cases': [
      {
        'case': 'wrong-analysis-node',
        'invocation': 'installed-route',
        'exit': 2,
        'error': 'NODE_UNAVAILABLE',
      },
    ],
  };
}

/// Checks the caller route, or explicitly labelled native supplements.
Future<List<Map<String, Object?>>> exerciseInstalledNodeAbsence(
  NpmInstalledControls controls, {
  required Map<String, String> environment,
  bool nativeSupplement = false,
}) async {
  final before = controls.snapshot();
  final checked = await controls.capture(
    ['--root', controls.project.path, 'check'],
    environment: environment,
    native: nativeSupplement,
    expectedExit: 2,
  );
  controls.incomplete(checked, 'NODE_UNAVAILABLE');
  final validated = await controls.capture(
    ['--root', controls.project.path, 'validate'],
    environment: environment,
    native: nativeSupplement,
  );
  final value = jsonDecode(utf8.decode(validated.stdout));
  controls.require(
    validated.stderr.isEmpty &&
        value['command'] == 'validate' &&
        value['exit_code'] == 0 &&
        value['status'] == 'ok',
    'Native validation unexpectedly requires Node',
  );
  controls.unchanged(before);
  return [
    {
      'case': nativeSupplement
          ? 'native-supplement-missing-node-check'
          : 'missing-analysis-node-check',
      'invocation': nativeSupplement
          ? 'installed-native-supplement'
          : 'installed-route',
      'exit': 2,
      'error': 'NODE_UNAVAILABLE',
    },
    {
      'case': nativeSupplement
          ? 'native-supplement-no-node-validate'
          : 'no-node-validate',
      'invocation': nativeSupplement
          ? 'installed-native-supplement'
          : 'installed-route',
      'exit': 0,
    },
  ];
}

Future<Map<String, Object?>> exerciseInstalledRuntimes(
  NpmInstalledControls controls, {
  required File wrongNode,
}) async {
  final verified = await verifyInstalledWrongNode(controls, wrongNode);
  final missing = Directory(
    '${controls.project.parent.path}/missing node runtime',
  );
  controls.require(
    FileSystemEntity.typeSync(missing.path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Missing-runtime control path already exists',
  );
  final environment = _withPath(controls, missing.path);
  final before = controls.snapshot();
  final launch = await controls.capture(
    ['--help'],
    environment: environment,
    expectedExit: null,
  );
  controls.require(
    launch.exitCode != 0 &&
        launch.stdout.isEmpty &&
        utf8.decode(launch.stderr).toLowerCase().contains('node'),
    'Missing npm launcher Node must fail outside core JSON',
  );
  controls.unchanged(before);
  return {
    'wrong_node': verified['wrong_node'],
    'cases': [
      ...verified['cases'] as List,
      {
        'case': 'missing-launcher-node',
        'invocation': 'installed-route',
        'exit': launch.exitCode,
        'launcher_stderr_only': true,
      },
      ...await exerciseInstalledNodeAbsence(
        controls,
        environment: environment,
        nativeSupplement: true,
      ),
    ],
  };
}
