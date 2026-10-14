// Bind official SDK preparation to the executable that activated the wrapper.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'prepare_native_acceptance.dart';
import 'release_execution_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';
import 'setup_pub_dart.dart';

void validatePubSdkReceipt(
  Directory artifact, {
  required Map<String, Object?> source,
  required String target,
  required String dart,
}) {
  final proof = receiptObject(
    readRecord(File(p.join(artifact.path, 'sdk-preparation.json'))),
  );
  final processes = validateInstalledProcessReceipts(
    proof['commands'],
    Directory(p.join(artifact.path, 'sdk-preparation-execution')),
    timeoutSeconds: {240},
  );
  validatePubSdkProcesses(
    proof,
    processes,
    source: source,
    target: target,
    dart: dart,
    checksum: utf8.decode(
      readOrdinaryBytes(
        File(p.join(artifact.path, 'dartsdk-$target-release.zip.sha256sum')),
        limit: 1024,
      ),
    ),
  );
}

void validatePubSdkProcesses(
  Map<String, dynamic> proof,
  List<InstalledProcessEvidence> processes, {
  required Map<String, Object?> source,
  required String target,
  required String dart,
  required String checksum,
}) {
  requireReceipt(pubSdkPins.containsKey(target), 'Unsupported pub SDK target');
  final paths = p.Context(
    style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
  );
  final root = paths.dirname(paths.dirname(paths.dirname(dart)));
  final name = 'dartsdk-$target-release.zip';
  final archive = receiptObject(proof['archive']);
  final size = archive['size'];
  final pin = pubSdkPins[target]!;
  requireReceipt(
    proof['schema_version'] is int &&
        proof['schema_version'] == 1 &&
        proof['target'] == target &&
        exactReceipt(proof['source'], source) &&
        proof['dart'] == dart &&
        paths.isAbsolute(dart) &&
        dart ==
            paths.join(
              root,
              'dart-sdk',
              'bin',
              target == 'windows-x64' ? 'dart.exe' : 'dart',
            ) &&
        proof['cache_prepared'] == true &&
        proof['prepared_cache'] == paths.join(root, 'pub-cache') &&
        archive.length == 3 &&
        archive['url'] == '$pubSdkBase$name' &&
        archive['sha256'] == pin &&
        size is int &&
        size > 0 &&
        size <= 512 * 1024 * 1024 &&
        RegExp('^$pin\\s+\\*?${RegExp.escape(name)}\$')
            .hasMatch(checksum.trim()),
    'Pub SDK source, archive or activation executable differs',
  );
  requireReceipt(
    processes.length == 3 &&
        processes.every((process) => process.exitCode == 0),
    'Pub SDK preparation process inventory or status differs',
  );
  final extraction = processes[0];
  final environment = <String, String>{};
  if (target == 'windows-x64') {
    final executable = extraction.arguments.first;
    final system = paths.dirname(paths.dirname(executable));
    requireReceipt(
      paths.isAbsolute(system),
      'SDK extraction system root differs',
    );
    environment['SystemRoot'] = system;
  }
  requireReceipt(
    exactReceipt(
          extraction.arguments,
          officialExtractionCommand(
            paths.join(root, name),
            root,
            target,
            environment,
          ),
        ) &&
        extraction.stdout.isEmpty &&
        extraction.stderr.isEmpty,
    'Pub SDK official extraction command differs',
  );
  final version = processes[1];
  final text = utf8.decode([...version.stdout, ...version.stderr]).trim();
  requireReceipt(
    exactReceipt(version.arguments, [dart, '--version']) &&
        text == proof['version'] &&
        RegExp(r'^Dart SDK version: 3\.13\.3(?:\s|$)').hasMatch(text),
    'Pub SDK original version differs',
  );
  requireReceipt(
    exactReceipt(processes[2].arguments, [
      dart,
      '--suppress-analytics',
      'pub',
      'get',
      '--enforce-lockfile',
    ]),
    'Pub SDK dependency preparation command differs',
  );
}
