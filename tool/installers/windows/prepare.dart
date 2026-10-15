// Converts an already verified Windows release bundle to Inno build inputs.
// Source/transport verification remains the release owner's prerequisite.
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../release/installation_artifact.dart';
import '../../release/native_manifest.dart';
import 'casefold.dart';

Future<void> prepareWindowsInstaller(
  Directory payload,
  Directory output,
) async {
  payload = payload.absolute;
  output = output.absolute;
  // Resolve the nearest existing ancestor without creating output directories.
  var ancestor = output;
  final missing = <String>[];
  while (await FileSystemEntity.type(ancestor.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    missing.insert(0, p.basename(ancestor.path));
    ancestor = ancestor.parent;
  }
  final prospective = p.joinAll([
    await ancestor.resolveSymbolicLinks(),
    ...missing,
  ]);
  final payloadPath = await payload.resolveSymbolicLinks();
  if (prospective != output.path ||
      prospective == payloadPath ||
      p.isWithin(payloadPath, prospective)) {
    throw const FormatException(
      'Inno build directory must be canonical and outside the payload',
    );
  }
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException('Inno build directory must be fresh');
  }
  final manifest = await readNativeManifest(
    File(p.join(payload.path, 'manifest.json')),
  );
  final inventory = manifest.completeArchiveInventory;
  if (manifest.manifest['target'] != 'windows-x64') {
    throw const FormatException('Expected Windows release manifest');
  }
  // Expected modes remain provenance; Windows cannot reproduce POSIX modes.
  await verifyInstallationDirectory(payload, inventory, compareModes: false);
  if (!inventory.files.containsKey('bin/windows-x64/archway.exe')) {
    throw const FormatException('Windows native command missing');
  }
  final rows = <String>[], entries = <String>[];
  final names = inventory.files.keys.toList()..sort(_comparePaths);
  final aliases = <String, String>{};
  for (final name in names) {
    final parts = name.split('/');
    for (var length = 1; length <= parts.length; length++) {
      final prefix = parts.take(length).join('/');
      final previous = aliases.putIfAbsent(
        installerCaseFold(prefix),
        () => prefix,
      );
      if (previous != prefix) {
        throw const FormatException('Case-aliased Windows installer member');
      }
    }
    if (parts.any((part) => RegExp(r'[<>"|?*{}]').hasMatch(part)) ||
        installerCaseFold(parts.first).startsWith('unins') ||
        installerCaseFold(parts.first).startsWith('.archway-')) {
      throw const FormatException('Unsafe Windows installer member');
    }
    rows.add('${inventory.files[name]!.sha256}\t${name.replaceAll('/', r'\')}');
    final source = p
        .joinAll([payload.path, ...parts])
        .replaceAll('"', '""')
        .replaceAll('{', '{{');
    final destination =
        '{app}${parts.length > 1 ? '\\${parts.take(parts.length - 1).join(r'\')}' : ''}';
    entries.add(
      'Source: "$source"; DestDir: "$destination"; Flags: ignoreversion',
    );
  }
  final newline = Platform.isWindows ? '\r\n' : '\n';
  await output.create(recursive: true);
  await File(p.join(output.path, 'owned-files.txt'))
      .writeAsString('${rows.join(newline)}$newline');
  await File(p.join(output.path, 'payload.iss'))
      .writeAsString('${entries.join(newline)}$newline');
  final scripts = File.fromUri(Platform.script).parent;
  for (final name in ['archway.iss', 'lifecycle.iss']) {
    await File(p.join(scripts.path, name)).copy(p.join(output.path, name));
  }
}

// Deterministic component ordering. ASCII order matches pathlib; rare Unicode
// Windows lowercase ordering can differ. Consumers process rows independently.
int _comparePaths(String left, String right) {
  final a = (Platform.isWindows ? left.toLowerCase() : left).split('/');
  final b = (Platform.isWindows ? right.toLowerCase() : right).split('/');
  for (var i = 0; i < a.length && i < b.length; i++) {
    final x = a[i].runes.toList(), y = b[i].runes.toList();
    for (var j = 0; j < x.length && j < y.length; j++) {
      if (x[j] != y[j]) return x[j].compareTo(y[j]);
    }
    if (x.length != y.length) return x.length.compareTo(y.length);
  }
  return a.length.compareTo(b.length);
}

Future<void> main(List<String> args) async {
  try {
    if (args.length != 2)
      throw const FormatException('Usage: prepare.dart PAYLOAD OUTPUT');
    await prepareWindowsInstaller(Directory(args[0]), Directory(args[1]));
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}
