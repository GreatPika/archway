// Shared bounded capture for maintainer fixture preparation.
import 'dart:convert';
import 'dart:io';

import 'native_acceptance_capture.dart';

void writePreparation(File file, String value) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(value);
}

Future<String> runPreparation(
  List<String> command,
  Map<String, String> environment,
  File log, {
  Directory? cwd,
  Duration timeout = const Duration(seconds: 240),
}) async {
  log.parent.createSync(recursive: true);
  final outFile = File('${log.path}.stdout'),
      errFile = File('${log.path}.stderr');
  final out = outFile.openSync(mode: FileMode.write);
  RandomAccessFile? err;
  int? code;
  try {
    err = errFile.openSync(mode: FileMode.write);
    code = await captureAcceptanceProcess(
      command,
      (cwd ?? Directory.current).path,
      environment,
      out,
      err,
      timeout,
    );
  } finally {
    try {
      out.closeSync();
    } finally {
      err?.closeSync();
    }
    if (err != null) {
      final output = [
        ...outFile.readAsBytesSync(),
        ...errFile.readAsBytesSync(),
      ];
      writePreparation(log, utf8.decode(output, allowMalformed: true));
      outFile.deleteSync();
      errFile.deleteSync();
    }
  }
  final output = log.readAsStringSync();
  if (code != 0)
    throw ProcessException(
      command.first,
      command.skip(1).toList(),
      'Preparation failed (see ${log.path})\n${output.length > 3000 ? output.substring(output.length - 3000) : output}',
      code,
    );
  return output.trim();
}
