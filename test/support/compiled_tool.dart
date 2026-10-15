// Reuse immutable tool compilation within one suite, never mutable inputs or
// process state. Only use for entrypoints independent of Platform.script.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Call from setUpAll so the owned kernel lives until that suite's teardown.
Future<File> prepareCompiledTool(String source) async {
  final directory = await Directory.systemTemp.createTemp(
    'archway-tool-kernel-',
  );
  addTearDown(() => directory.delete(recursive: true));
  final kernel = File(p.join(directory.path, 'tool.dill'));
  final result = await Process.run(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'compile',
    'kernel',
    p.absolute(source),
    '-o',
    kernel.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  expect(kernel.existsSync(), isTrue);
  return kernel;
}
