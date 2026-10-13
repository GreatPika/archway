import 'dart:io';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  require(Platform.isWindows, 'This readiness probe requires native Windows.');
  final systemRoot = Platform.environment['SystemRoot'];
  final configuredTemp = Platform.environment['TEMP'];
  require(
    systemRoot != null && configuredTemp != null,
    'Windows environment missing.',
  );
  final actualTemp = Directory.systemTemp.resolveSymbolicLinksSync();
  require(
    actualTemp == Directory(configuredTemp!).resolveSymbolicLinksSync(),
    'Dart systemTemp differs from the inspected adapter temp base.',
  );
  print('FILE_ALIAS_TEMP=$actualTemp');
  final root = Directory(actualTemp).createTempSync('archway-file-alias-');
  final first = File('${root.path}/first.json');
  final second = File('${root.path}/second.json');
  final alias = Link('${root.path}/config.alias.json');
  void checkTarget(String target, File file, String bytes) {
    require(
      FileSystemEntity.typeSync(alias.path, followLinks: false) ==
          FileSystemEntityType.link,
      'Expected an actual file symbolic link.',
    );
    require(
      alias.targetSync() == target,
      'Relative link target bytes changed.',
    );
    require(
      File(alias.path).resolveSymbolicLinksSync() ==
          file.resolveSymbolicLinksSync(),
      'File link canonical target mismatch.',
    );
    require(
      File(alias.path).readAsStringSync() == bytes,
      'File link content mismatch.',
    );
  }

  Future<void> checkTag() async {
    final result = await Process.run('$systemRoot/System32/fsutil.exe', [
      'reparsepoint',
      'query',
      alias.path,
    ]);
    require(
      result.exitCode == 0,
      'fsutil failed: ${result.stdout} ${result.stderr}',
    );
    print('FILE_ALIAS_REPARSE_DATA=${result.stdout}');
    require(
      RegExp(
        r'0xa000000c\b',
        caseSensitive: false,
      ).hasMatch('${result.stdout}'),
      'Require IO_REPARSE_TAG_SYMLINK, never a junction.',
    );
  }

  try {
    first.writeAsStringSync('first bytes');
    second.writeAsStringSync('second bytes');
    await alias.create('first.json');
    checkTarget('first.json', first, 'first bytes');
    await checkTag();
    alias.updateSync('second.json');
    checkTarget('second.json', second, 'second bytes');
    alias.updateSync('first.json');
    checkTarget('first.json', first, 'first bytes');
    alias.updateSync('config.alias.json');
    require(
      FileSystemEntity.typeSync(alias.path, followLinks: false) ==
          FileSystemEntityType.link,
      'Self-cycle must remain a link.',
    );
    require(
      alias.targetSync() == 'config.alias.json',
      'Self-cycle raw target mismatch.',
    );
    await checkTag();
    var resolutionFailed = false;
    try {
      File(alias.path).resolveSymbolicLinksSync();
    } on FileSystemException {
      resolutionFailed = true;
    }
    require(resolutionFailed, 'Self-cycle resolution unexpectedly succeeded.');
    alias.deleteSync();
    require(
      FileSystemEntity.typeSync(alias.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Link deletion left a filesystem entry.',
    );
    require(
      FileSystemEntity.typeSync(first.path, followLinks: false) ==
              FileSystemEntityType.file &&
          FileSystemEntity.typeSync(second.path, followLinks: false) ==
              FileSystemEntityType.file &&
          first.readAsStringSync() == 'first bytes' &&
          second.readAsStringSync() == 'second bytes',
      'Deleting the link changed its ordinary targets.',
    );
  } finally {
    if (FileSystemEntity.typeSync(alias.path, followLinks: false) ==
        FileSystemEntityType.link) {
      alias.deleteSync();
    }
    root.deleteSync(recursive: true);
  }
  print(
    'FILE_ALIAS_FIXTURE_READY tag=0xa000000c create=relative retarget=passed restore=passed self_cycle=passed targets_intact=true',
  );
}
