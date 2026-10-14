// Isolated Linux supervisor: never make the test runner a child subreaper.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../../tool/validation/json_schema.dart';
import '../alias_hop_recheck_process_smoke.dart' as alias;
import 'process_lifecycle.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isLinux || arguments.length != 1) {
    throw StateError('Linux supervisor requires its owned fixture directory');
  }
  final libc = DynamicLibrary.process();
  final prctl = libc
      .lookupFunction<
        Int32 Function(Int32, IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, int, int, int, int)
      >('prctl');
  final waitpid = libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)
      >('waitpid');
  final currentErrno = libc
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  final errno = currentErrno();
  if (prctl(36, 1, 0, 0, 0) != 0) {
    throw OSError('PR_SET_CHILD_SUBREAPER', errno.value);
  }
  final node = Platform.environment['ARCHWAY_TEST_NODE'];
  if (node == null || !File(node).isAbsolute || !File(node).existsSync()) {
    throw StateError('Prepared absolute ARCHWAY_TEST_NODE required');
  }
  final root = Directory(arguments.single);
  final project = Directory('${root.path}/project')..createSync();
  File('${project.path}/architecture.yaml').writeAsStringSync(
    'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
  );
  final pidFile = File('${root.path}/child.pid');
  final driver = File('${root.path}/driver.dart');
  final entrypoint = Platform.script.resolve('../../bin/archway.dart');
  driver.writeAsStringSync('''
import 'dart:io';
import '${entrypoint.toString()}' as command;
Future<void> main() async {
  final child = await Process.start(${jsonEncode(node)},
    ['-e', 'setTimeout(()=>{},20000)']);
  await child.stdin.close();
  await child.stdout.listen((_) {}).cancel();
  await child.stderr.listen((_) {}).cancel();
  await File(${jsonEncode(pidFile.path)}).writeAsString('\${child.pid}');
  await command.main(['--root', ${jsonEncode(project.path)}, 'validate']);
}
''');
  // Prepare the real imported entrypoint before measuring its process behavior.
  // Frontend compilation is not the pending-child exit contract.
  final kernel = '${root.path}/driver.dill';
  final compilation = await alias.capture(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    driver.path,
    '-o',
    kernel,
  ]);
  if (compilation.code != 0) {
    throw StateError(
      'Driver preparation failed: ${utf8.decode(compilation.err)}',
    );
  }
  Process? parent;
  Future<int>? parentExit;
  Future<String>? errors;
  StreamSubscription<List<int>>? output;
  final firstLine = Completer<List<int>>();
  final outputDone = Completer<void>();
  final bytes = <int>[];
  int? newline;
  Object? failure;
  StackTrace? failureStack;
  try {
    parent = await Process.start(Platform.resolvedExecutable, [kernel]);
    parentExit = parent.exitCode;
    errors = parent.stderr.transform(utf8.decoder).join();
    output = parent.stdout.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (!firstLine.isCompleted) {
          final index = bytes.indexOf(10);
          if (index >= 0) {
            newline = index;
            firstLine.complete(bytes.sublist(0, index + 1));
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!firstLine.isCompleted) firstLine.completeError(error, stack);
        if (!outputDone.isCompleted) outputDone.completeError(error, stack);
      },
      onDone: () {
        if (!firstLine.isCompleted) {
          firstLine.completeError(StateError('No newline-terminated report'));
        }
        if (!outputDone.isCompleted) outputDone.complete();
      },
    );
    outputDone.future.ignore();
    final line = await firstLine.future.timeout(const Duration(seconds: 15));
    // Begin the exit deadline at the flushed report, before schema validation.
    final code = await parentExit.timeout(
      const Duration(seconds: 1),
      onTimeout: () => throw StateError(
        'Entrypoint stayed alive after flushed report because a native child handle is pending',
      ),
    );
    await outputDone.future.timeout(const Duration(seconds: 1));
    final error = await errors.timeout(const Duration(seconds: 1));
    final value = jsonDecode(utf8.decode(line));
    final schemaErrors = ContractSchema(
      jsonDecode(
        File.fromUri(
          Platform.script.resolve(
            '../../contracts/json/public-result.schema.json',
          ),
        ).readAsStringSync(),
      ),
    ).errors(value);
    if (schemaErrors.isNotEmpty)
      throw StateError('Invalid public report: $schemaErrors');
    if (code != 0 ||
        value['exit_code'] != 0 ||
        bytes.length != newline! + 1 ||
        error.isNotEmpty) {
      throw StateError('Unexpected entrypoint exit, output, or diagnostics');
    }
    if (!isProcessAlive(int.parse(pidFile.readAsStringSync()))) {
      throw StateError('Pending child exited before entrypoint assertion');
    }
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  } finally {
    var child = pidFile.existsSync()
        ? int.parse(pidFile.readAsStringSync())
        : null;
    if (child != null) terminateProcessId(child);
    try {
      if (parent != null) {
        try {
          await parentExit!.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          parent.kill(ProcessSignal.sigkill);
          await parentExit!.timeout(const Duration(seconds: 5));
        }
      }
    } finally {
      // Compilation may finish during parent teardown. Discover and own that
      // late-spawned child only after the parent can no longer create one.
      child ??= pidFile.existsSync()
          ? int.parse(pidFile.readAsStringSync())
          : null;
      if (child != null) {
        terminateProcessId(child);
        final deadline = Stopwatch()..start();
        while (true) {
          final errno = currentErrno();
          final reaped = waitpid(child, nullptr, 1); // WNOHANG
          final error = errno.value;
          if (reaped == child) break;
          if (reaped == -1 && error == 10 && !isProcessAlive(child)) break;
          if (reaped == -1 && error != 4) throw OSError('waitpid', error);
          if (deadline.elapsed >= const Duration(seconds: 5)) {
            throw StateError('Owned pending child could not be reaped');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (isProcessAlive(child))
          throw StateError('Pending child survived cleanup');
        File('${root.path}/reaped').writeAsStringSync('$child');
      }
      await output?.cancel();
    }
  }
  if (failure != null) {
    final diagnostics = errors == null
        ? ''
        : await errors.timeout(const Duration(seconds: 1));
    stderr.writeln('Driver failure: $failure; stderr: $diagnostics');
    Error.throwWithStackTrace(failure, failureStack!);
  }
  stdout.writeln(
    'entrypoint exit/schema verified; pending child killed and reaped',
  );
}
