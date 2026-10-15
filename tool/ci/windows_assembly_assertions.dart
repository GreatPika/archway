// Real Windows assembler refusal/cleanup controls; no rebuild or fake compiler.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../validation/json_values.dart';

Future<void> assertWindowsAssemblyGuards(
  Directory repo,
  String powershell,
  File dart,
  Directory base,
) async {
  if (!Platform.isWindows)
    throw UnsupportedError('Windows assembly guards require native Windows.');
  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  List<String> children(Directory directory) =>
      directory
          .listSync(followLinks: false)
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();
  Future<NativeProcessResult> assemble(Directory source, String output) async {
    final result = await runNativeProcess(
      [
        powershell,
        '-NoProfile',
        '-File',
        p.join(source.path, 'tool/assemble_windows.ps1'),
        '-Output',
        output,
        '-Dart',
        dart.path,
      ],
      workingDirectory: base.path,
      timeout: const Duration(seconds: 30),
    );
    print('Assembler refusal exit: ${result.exitCode}');
    print(
      'Assembler stdout: ${jsonEncode(utf8.decode(result.stdout, allowMalformed: true))}',
    );
    print(
      'Assembler stderr: ${jsonEncode(utf8.decode(result.stderr, allowMalformed: true))}',
    );
    require(
      result.exitCode != 0,
      'Assembler must refuse this unsafe/incomplete request.',
    );
    return result;
  }

  final existing = Directory(p.join(base.path, 'existing output café'))
    ..createSync();
  final sentinel = File(p.join(existing.path, 'keep ü.txt'));
  const bytes = 'Caller-owned output must not be overwritten.\n';
  sentinel.writeAsStringSync(bytes);
  var before = children(base);
  var result = await assemble(repo, existing.path);
  require(
    utf8.decode(result.stderr).contains('Assembly output already exists'),
    'Missing existing-output refusal.',
  );
  require(
    sameJson(children(existing), ['keep ü.txt']) &&
        sentinel.readAsStringSync() == bytes,
    'Assembler modified caller-owned output.',
  );
  require(sameJson(children(base), before), 'Assembler changed siblings.');
  print('WINDOWS_ASSEMBLY_EXISTING_OUTPUT_REFUSED');

  final target = Directory(p.join(base.path, 'real output parent ü'))
    ..createSync();
  final alias = p.join(base.path, 'aliased output parent café');
  final environment = {
    ...Platform.environment,
    'ARCHWAY_ASSEMBLY_ALIAS': alias,
    'ARCHWAY_ASSEMBLY_TARGET': target.path,
  };
  final created = await runNativeProcess(
    [
      powershell,
      '-NoProfile',
      '-Command',
      "\$ErrorActionPreference = 'Stop'; New-Item -ItemType Junction -Path \$env:ARCHWAY_ASSEMBLY_ALIAS -Target \$env:ARCHWAY_ASSEMBLY_TARGET | Out-Null",
    ],
    workingDirectory: base.path,
    environment: environment,
    timeout: const Duration(seconds: 30),
  );
  require(
    created.exitCode == 0,
    'Cannot create real assembly junction: ${utf8.decode(created.stderr)}',
  );
  try {
    final systemRoot = Platform.environment['SystemRoot'];
    require(systemRoot != null, 'Missing Windows SystemRoot.');
    final queried = await runNativeProcess(
      [
        p.join(systemRoot!, 'System32/fsutil.exe'),
        'reparsepoint',
        'query',
        alias,
      ],
      workingDirectory: base.path,
      timeout: const Duration(seconds: 30),
    );
    require(
      queried.exitCode == 0 &&
          RegExp(
            r'0xa0000003\b',
            caseSensitive: false,
          ).hasMatch(utf8.decode(queried.stdout, allowMalformed: true)),
      'Require IO_REPARSE_TAG_MOUNT_POINT.',
    );
    require(
      Directory(alias).resolveSymbolicLinksSync() ==
          target.resolveSymbolicLinksSync(),
      'Junction target mismatch.',
    );
    print('WINDOWS_ASSEMBLY_JUNCTION_READY tag=0xa0000003');
    before = children(base);
    result = await assemble(repo, p.join(alias, 'refused installation'));
    require(
      utf8.decode(result.stderr).contains('Assembly path is a reparse point'),
      'Missing alias-parent refusal.',
    );
    require(
      children(target).isEmpty && sameJson(children(base), before),
      'Assembler changed junction target or siblings.',
    );
    print('WINDOWS_ASSEMBLY_ALIASED_PARENT_REFUSED');
  } finally {
    // Directory.Delete(path) is nonrecursive: remove only the owned junction.
    final removed = await runNativeProcess(
      [
        powershell,
        '-NoProfile',
        '-Command',
        "\$ErrorActionPreference = 'Stop'; [IO.Directory]::Delete(\$env:ARCHWAY_ASSEMBLY_ALIAS)",
      ],
      workingDirectory: base.path,
      environment: environment,
      timeout: const Duration(seconds: 30),
    );
    require(
      removed.exitCode == 0,
      'Cannot remove owned junction without traversal.',
    );
  }

  final fixture = Directory(p.join(base.path, 'incomplete owned sources café'));
  for (final relative in [
    'tool/assemble_windows.ps1',
    'tool/build_native_windows.ps1',
    'bin/archway.dart',
  ]) {
    final destination = File(p.join(fixture.path, relative));
    destination.parent.createSync(recursive: true);
    File(p.join(repo.path, relative)).copySync(destination.path);
  }
  void copyTree(Directory source, Directory destination) {
    destination.createSync(recursive: true);
    for (final entity in source.listSync(followLinks: false)) {
      final path = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        copyTree(entity, Directory(path));
      } else {
        require(
          entity is File,
          'Owned source fixture must not contain aliases.',
        );
        File(entity.path).copySync(path);
      }
    }
  }

  final assets = Directory(p.join(fixture.path, 'assets/typescript'));
  copyTree(Directory(p.join(repo.path, 'assets/typescript')), assets);
  Directory(p.join(assets.path, 'licenses')).deleteSync(recursive: true);
  final parent = Directory(p.join(base.path, 'failed assembly output ü'))
    ..createSync();
  final failed = p.join(parent.path, 'installation');
  result = await assemble(fixture, failed);
  require(
    utf8.decode(result.stderr).contains('licenses'),
    'Missing incomplete-source refusal.',
  );
  require(
    FileSystemEntity.typeSync(failed, followLinks: false) ==
            FileSystemEntityType.notFound &&
        children(parent).isEmpty,
    'Failed assembly must clean its stage and build scratch.',
  );
  print('WINDOWS_ASSEMBLY_FAILURE_CLEANUP_PASSED');
}
