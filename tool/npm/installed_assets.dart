// Destructive controls bind the installed wrapper and its separate native cache.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../ci/installed_command_recorder.dart';
import '../ci/native_acceptance.dart';
import '../ci/release_execution_receipts.dart';
import '../validation/json_values.dart';

final class NpmInstalledControls {
  NpmInstalledControls({
    required this.executable,
    required this.command,
    required this.project,
    required this.cwd,
    required this.wrapper,
    required this.payload,
    required this.target,
    required this.environment,
    required this.recorder,
    this.launcherErrorPrefix = 'archway launcher:',
  }) {
    for (final directory in [project, cwd, wrapper, payload]) {
      require(
        directory.resolveSymbolicLinksSync() == directory.path,
        'Installed control directory must be canonical',
      );
    }
    require(
      ['linux-x64', 'macos-arm64', 'windows-x64'].contains(target),
      'Unsupported installed target',
    );
  }

  final File executable;
  final List<String> Function(List<String>) command;
  final Directory project, cwd, wrapper, payload;
  final String target, launcherErrorPrefix;
  final Map<String, String> environment;
  final InstalledCommandRecorder recorder;

  File get nativeExecutable => File(
    p.join(
      payload.path,
      'bin',
      target,
      target == 'windows-x64' ? 'archway.exe' : 'archway',
    ),
  );

  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Map<String, Object?> _snapshot(Directory root) => {
    for (final entry in root.listSync(recursive: true, followLinks: false))
      p.relative(entry.path, from: root.path): entry is Link
          ? ['link', entry.targetSync()]
          : entry is Directory
          ? ['directory']
          : [
              'file',
              sha256.convert(File(entry.path).readAsBytesSync()).toString(),
            ],
  };

  List<Object?> snapshot() => [
    for (final directory in [project, cwd, wrapper, payload])
      _snapshot(directory),
  ];

  void unchanged(List<Object?> before) => require(
    sameJson(snapshot(), before),
    'Installed control unexpectedly changed files',
  );

  Future<NativeProcessResult> capture(
    List<String> arguments, {
    Map<String, String>? environment,
    int? expectedExit = 0,
    bool native = false,
  }) async {
    final invocation = native
        ? [nativeExecutable.path, ...arguments]
        : command([executable.path, ...arguments]);
    try {
      return await recorder.capture(
        invocation,
        workingDirectory: cwd.path,
        environment: environment ?? this.environment,
        expectedExit: expectedExit ?? 0,
      );
    } on SuiteExitFailure catch (failure) {
      if (expectedExit != null) rethrow;
      return (
        exitCode: failure.proof['exit_code'] as int,
        stdout: readOrdinaryBytes(
          File(p.join(recorder.output.path, failure.proof['stdout'] as String)),
        ),
        stderr: readOrdinaryBytes(
          File(p.join(recorder.output.path, failure.proof['stderr'] as String)),
        ),
      );
    }
  }

  Map<String, dynamic> checkResult(
    NativeProcessResult result,
    int code,
    String status,
  ) {
    require(
      result.exitCode == code &&
          result.stderr.isEmpty &&
          result.stdout.isNotEmpty &&
          result.stdout.last == 10 &&
          result.stdout.where((byte) => byte == 10).length == 1 &&
          !sameJson(result.stdout.take(3).toList(), [239, 187, 191]),
      'Unexpected installed check streams or exit',
    );
    final value =
        jsonDecode(utf8.decode(result.stdout)) as Map<String, dynamic>;
    require(
      value['schema_version'] == 1 &&
          value['command'] == 'check' &&
          value['exit_code'] == code &&
          value['status'] == status,
      'Unexpected installed check envelope',
    );
    return value;
  }

  void incomplete(NativeProcessResult result, String error) {
    final payload = checkResult(result, 2, 'incomplete')['payload'];
    require(
      payload['analysis_complete'] == false &&
          sameJson(
            (payload['tool_errors'] as List).map((e) => e['code']).toList(),
            [error],
          ),
      'Unexpected installed analysis error: expected $error',
    );
  }
}

Future<List<Map<String, Object?>>> exerciseInstalledAssets(
  NpmInstalledControls controls,
) async {
  final cases = <Map<String, Object?>>[];
  Future<void> check(String name, String error) async {
    final before = controls.snapshot();
    final result = await controls.capture([
      '--root',
      controls.project.path,
      'check',
    ], expectedExit: 2);
    controls.incomplete(result, error);
    controls.unchanged(before);
    cases.add({'case': name, 'exit': 2, 'error': error});
  }

  Future<void> prelaunch(String name) async {
    final before = controls.snapshot();
    final result = await controls.capture(['--help'], expectedExit: 126);
    controls.require(
      result.stdout.isEmpty &&
          utf8.decode(result.stderr).startsWith(controls.launcherErrorPrefix),
      'Expected stderr-only launcher prelaunch refusal',
    );
    controls.unchanged(before);
    cases.add({'case': name, 'exit': 126, 'error': 'launcher-prelaunch'});
  }

  for (final (name, relative) in [
    ('helper', ['assets', 'typescript', 'helper.cjs']),
    (
      'compiler',
      ['assets', 'typescript', 'vendor', 'typescript', 'lib', 'typescript.js'],
    ),
    (
      'payload',
      ['bin', controls.target, p.basename(controls.nativeExecutable.path)],
    ),
    ('manifest', ['manifest.json']),
  ]) {
    final asset = File(p.joinAll([controls.payload.path, ...relative]));
    final saved = File('${asset.path}.control-saved');
    controls.require(
      FileSystemEntity.typeSync(saved.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Asset control backup already exists',
    );
    final original = controls.snapshot();
    Future<void> missingOrAlias(String kind) =>
        name == 'helper' || name == 'compiler'
        ? check('$kind-$name', 'TYPESCRIPT_ASSETS_UNAVAILABLE')
        : prelaunch('$kind-$name');
    asset.renameSync(saved.path);
    try {
      // Missing helper is already owned by runInstalledCommands.
      if (name != 'helper') await missingOrAlias('missing');
      final alias = Link(asset.path)..createSync(p.basename(saved.path));
      controls.require(
        FileSystemEntity.typeSync(alias.path, followLinks: false) ==
                FileSystemEntityType.link &&
            alias.targetSync() == p.basename(saved.path) &&
            alias.resolveSymbolicLinksSync() == saved.path &&
            sha256.convert(File(alias.path).readAsBytesSync()) ==
                sha256.convert(saved.readAsBytesSync()),
        'Asset alias did not select its saved bytes',
      );
      await missingOrAlias('aliased');
    } finally {
      if (FileSystemEntity.typeSync(asset.path, followLinks: false) ==
          FileSystemEntityType.link) {
        Link(asset.path).deleteSync();
      }
      saved.renameSync(asset.path);
      controls.unchanged(original);
    }
    final bytes = asset.readAsBytesSync();
    try {
      asset.writeAsStringSync('not a valid payload or manifest!');
      if (name == 'helper' || name == 'compiler') {
        await check(
          'corrupt-$name',
          name == 'helper'
              ? 'TYPESCRIPT_HELPER_FAILED'
              : 'TYPESCRIPT_LOAD_FAILED',
        );
      } else {
        await prelaunch('corrupt-$name');
      }
    } finally {
      asset.writeAsBytesSync(bytes);
      controls.unchanged(original);
    }
  }
  final before = controls.snapshot();
  final recovered = await controls.capture(['--help']);
  controls.require(
    recovered.stderr.isEmpty &&
        utf8.decode(recovered.stdout).startsWith('archway [--root ROOT]'),
    'Installed help did not recover after asset restoration',
  );
  controls.unchanged(before);
  cases.add({'case': 'restored-payload-help', 'exit': 0});
  return cases;
}

Future<Map<String, Object?>> exerciseInstalledCorpus(
  NpmInstalledControls controls, {
  required File selected,
}) async {
  if (!p.isWithin(controls.project.path, controls.wrapper.path)) {
    return {
      'applicable': false,
      'reason': 'installation-outside-inspected-root',
      'cases': [],
    };
  }
  controls.require(
    p.isWithin(controls.wrapper.path, selected.path) &&
        FileSystemEntity.typeSync(selected.path, followLinks: false) ==
            FileSystemEntityType.file &&
        selected.resolveSymbolicLinksSync() == selected.path,
    'Select an actual canonical installed wrapper source',
  );
  final relative = p.posix.joinAll(
    p.split(p.relative(selected.path, from: controls.project.path)),
  );
  final policy = File(p.join(controls.project.path, 'architecture.yaml'));
  final original = policy.readAsBytesSync();
  final text = utf8.decode(original);
  controls.require(
    text.contains('scope: [src/]') && text.contains('exclude: []'),
    'Installed corpus controls need the prepared two-file policy',
  );
  final expanded = text.replaceFirst(
    'scope: [src/]',
    'scope: [src/, ${jsonEncode(relative)}]',
  );
  final cases = <Map<String, Object?>>[];
  try {
    for (final excluded in [false, true]) {
      policy.writeAsStringSync(
        excluded
            ? expanded.replaceFirst(
                'exclude: []',
                'exclude: [${jsonEncode(relative)}]',
              )
            : expanded,
      );
      final before = controls.snapshot();
      final code = excluded ? 0 : 2;
      final result = await controls.capture([
        '--root',
        controls.project.path,
        'check',
      ], expectedExit: code);
      final value = controls.checkResult(
        result,
        code,
        excluded ? 'ok' : 'incomplete',
      );
      final payload = value['payload'];
      final paths = (payload['coverage']['files'] as List).map(
        (file) => file['path'],
      );
      controls.require(
        payload['analysis_complete'] == excluded &&
            paths.contains(relative) == !excluded &&
            payload['observed']['files'] == (excluded ? 2 : 3),
        'Installed source selection/exclusion changed the requested corpus',
      );
      controls.unchanged(before);
      cases.add({
        'case': '${excluded ? 'excluded' : 'selected'}-installed-corpus',
        'exit': code,
        'selected_present': !excluded,
        'observed_files': payload['observed']['files'],
      });
    }
  } finally {
    policy.writeAsBytesSync(original);
    controls.require(
      sameJson(policy.readAsBytesSync(), original),
      'Corpus policy bytes were not restored exactly',
    );
  }
  return {'applicable': true, 'selected_path': relative, 'cases': cases};
}
