// Prepare only the reviewed official negative-control runtime, before inspection.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import 'native_fixture_pins.dart';
import 'installed_command_recorder.dart';
import 'preparation_process.dart';
import 'prepare_native_acceptance.dart'
    show
        downloadFixture,
        fixtureSha,
        officialExtractionCommand,
        wrongNodeBase,
        wrongNodeName,
        wrongNodePath;

Future<Map<String, Object?>> prepareNpmWrongNode({
  required String target,
  required Directory output,
  File? archive,
}) async {
  final host = switch (Abi.current()) {
    Abi.linuxX64 => 'linux-x64',
    Abi.macosArm64 => 'macos-arm64',
    Abi.windowsX64 => 'windows-x64',
    _ => 'unsupported',
  };
  if (target != host || !fixtureWrongNodePins.containsKey(target))
    throw ArgumentError('Wrong-Node target differs from actual host');
  if (output.parent.resolveSymbolicLinksSync() != output.parent.path ||
      FileSystemEntity.typeSync(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw StateError(
      'Wrong-Node output must be absent with a canonical parent',
    );
  }
  output.createSync();
  final pin = fixtureWrongNodePins[target]!;
  final name = wrongNodeName(target);
  final url = '$wrongNodeBase$name';
  if (archive == null) {
    final sums = File(p.join(output.path, 'SHASUMS256.txt'));
    await downloadFixture(
      Uri.parse('${wrongNodeBase}SHASUMS256.txt'),
      sums,
      maxBytes: 4 * 1024 * 1024,
    );
    final matches = sums
        .readAsLinesSync()
        .map((line) => line.trim().split(RegExp(r'\s+')))
        .where((parts) => parts.length == 2 && parts[1] == name)
        .toList();
    if (matches.length != 1 || matches.single[0] != pin.sha256)
      throw const FormatException(
        'Official wrong-Node checksum differs from reviewed pin',
      );
    archive = File(p.join(output.path, name));
    await downloadFixture(
      Uri.parse(url),
      archive,
      expected: pin.sha256,
      maxBytes: maxArchiveBytes,
    );
  }
  final environment = Map<String, String>.from(Platform.environment)
    ..removeWhere(
      (key, _) => ['node_options', 'node_path'].contains(key.toLowerCase()),
    );
  await withArchiveInput(archive, (input) async {
    if (input.sha256 != pin.sha256)
      throw const FormatException('Wrong-Node archive checksum mismatch');
    final named = await input.file.copy(p.join(input.file.parent.path, name));
    await runPreparation(
      officialExtractionCommand(named.path, output.path, target, environment),
      environment,
      File(p.join(output.path, 'extraction.log')),
      cwd: output,
      timeout: const Duration(seconds: 300),
    );
  });
  final node = File(wrongNodePath(output, target));
  final recorder = InstalledCommandRecorder(
    output: Directory(p.join(output.path, 'identity'))..createSync(),
  );
  final version = await recorder.capture(
    [node.path, '--version'],
    environment: environment,
    workingDirectory: output.path,
    timeout: const Duration(seconds: 30),
  );
  if (utf8.decode(version.stdout).trim() != 'v$fixtureWrongNodeVersion' ||
      version.stderr.isNotEmpty)
    throw StateError('Wrong-Node executable version differs');
  File(p.join(output.path, 'identity/processes.json'))
      .writeAsStringSync('${jsonEncode(recorder.commands)}\n');
  final record = <String, Object?>{
    'target': target,
    'version': fixtureWrongNodeVersion,
    'url': url,
    'archive_sha256': pin.sha256,
    'executable': node.path,
    'executable_sha256': await fixtureSha(node),
  };
  File(p.join(output.path, 'runtime.json'))
      .writeAsStringSync('${jsonEncode(record)}\n');
  return record;
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('target', mandatory: true)
    ..addOption('output', mandatory: true)
    ..addOption('archive');
  try {
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty)
      throw ArgumentError('Unexpected runtime preparation arguments');
    final record = await prepareNpmWrongNode(
      target: args['target'] as String,
      output: Directory(args['output'] as String).absolute,
      archive: args['archive'] == null
          ? null
          : File(args['archive'] as String).absolute,
    );
    final node = record['executable'] as String;
    final github = Platform.environment['GITHUB_ENV'];
    if (github != null) {
      if (node.contains(RegExp(r'[\r\n]')))
        throw StateError('Invalid runtime environment path');
      File(
        github,
      ).writeAsStringSync('ARCHWAY_WRONG_NODE=$node\n', mode: FileMode.append);
    }
    stdout.writeln(jsonEncode(record));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
