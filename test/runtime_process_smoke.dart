// Real installed helper lifecycle, EOF, byte budgets and production deadline.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import 'support/installation_staging.dart';
import 'support/process_lifecycle.dart';
import 'support/windows_console.dart';
import 'support/windows_job.dart';
import 'support/windows_process.dart';
import 'support/windows_process_pipes.dart';

typedef _Captured = ({int code, List<int> out, List<int> err});
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

// Each Windows launch belongs to an owned Job before its first instruction.
// POSIX retains the direct child and concurrently observes exit and both EOFs.
final class _Child {
  Process? _posix;
  WindowsJob? _job;
  WindowsSuspendedProcess? _windows;
  WindowsProcessPipes? _pipes;
  Future<_Captured>? _completion;
  bool _exited = false;
  final _out = <int>[], _err = <int>[];
  final _eofs = [Completer<void>(), Completer<void>()];
  final _subscriptions = <StreamSubscription<List<int>>>[];

  static Future<_Child> start(
    List<String> command, {
    required String cwd,
    required Map<String, String> environment,
    bool interruptible = false,
  }) async {
    final child = _Child();
    try {
      if (Platform.isWindows) {
        child._job = WindowsJob();
        child._pipes = WindowsProcessPipes();
        child._windows = interruptible
            ? startWindowsInterruptible(
                child._job!,
                command,
                workingDirectory: cwd,
                environment: environment,
                output: child._pipes,
              )
            : child._job!.spawn(
                command,
                workingDirectory: cwd,
                environment: environment,
                output: child._pipes,
              );
      } else {
        final process = child._posix = await Process.start(
          command.first,
          command.sublist(1),
          workingDirectory: cwd,
          environment: environment,
          includeParentEnvironment: false,
        );
        final completion = process.exitCode.then((code) {
          child._exited = true;
          return code;
        });
        child._completion =
            Future.wait<dynamic>([
              completion,
              ...child._eofs.map((done) => done.future),
            ], eagerError: true).then(
              (values) =>
                  (code: values[0] as int, out: child._out, err: child._err),
            );
        child._completion!.ignore();
        final streams = [process.stdout, process.stderr];
        final buffers = [child._out, child._err];
        for (var index = 0; index < streams.length; index++) {
          final done = child._eofs[index];
          child._subscriptions.add(
            streams[index].listen(
              buffers[index].addAll,
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
              onError: (Object error, StackTrace stack) {
                if (!done.isCompleted) done.completeError(error, stack);
              },
            ),
          );
        }
        await process.stdin.close();
      }
      return child;
    } catch (_) {
      await child.close(operationFailed: true);
      rethrow;
    }
  }

  Future<_Captured> capture(Duration timeout) async {
    if (_pipes case final pipes?) {
      final result = await pipes.communicate(() => _windows!.exitCode, timeout);
      return (code: result.exitCode, out: result.stdout, err: result.stderr);
    }
    return _completion!.timeout(timeout);
  }

  Future<void> interrupt(String? sender) async {
    if (_windows case final target?) {
      await runWindowsConsoleSender([sender!, '${target.pid}']);
    } else {
      check(_posix!.kill(ProcessSignal.sigint), 'SIGINT delivery refused');
    }
  }

  Future<void> close({bool operationFailed = false}) async {
    if (Platform.isWindows) {
      finishWindowsConsoleCleanup([
        () => _job?.close(),
        () => _windows?.close(),
        () => _pipes?.close(),
      ], operationFailed: operationFailed);
    } else {
      Object? failure;
      StackTrace? trace;
      try {
        if (_posix != null && !_exited) {
          _posix!.kill(ProcessSignal.sigkill);
          await _posix!.exitCode.timeout(const Duration(seconds: 5));
        }
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      try {
        // Start both cancellations even when one throws; timeout does not own
        // these subscriptions, and direct-child exit does not imply pipe EOF.
        await Future.wait(
          _subscriptions.map((stream) async => await stream.cancel()),
        ).timeout(const Duration(seconds: 5));
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      } finally {
        for (final done in _eofs) {
          if (_completion != null && !done.isCompleted)
            done.completeError(StateError('Capture closed before EOF'));
        }
      }
      if (!operationFailed && failure != null)
        Error.throwWithStackTrace(failure, trace!);
    }
  }
}

Future<_Captured> capture(
  List<String> command, {
  required String cwd,
  required Map<String, String> environment,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final child = await _Child.start(command, cwd: cwd, environment: environment);
  var failed = false;
  try {
    return await child.capture(timeout);
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    await child.close(operationFailed: failed);
  }
}

// Atomic publication: readers never interpret an empty/partially written PID.
String publishPid(File marker) =>
    "const fs=require('node:fs');const marker=${jsonEncode(marker.path)};fs.writeFileSync(marker+'.pending',String(process.pid));fs.renameSync(marker+'.pending',marker);";
Future<int> readyPid(File marker) async {
  final elapsed = Stopwatch()..start();
  while (!marker.existsSync()) {
    check(elapsed.elapsed < const Duration(seconds: 5), 'Helper did not start');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final value = int.parse(marker.readAsStringSync());
  check(value > 0, 'Invalid helper PID');
  return value;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run test/runtime_process_smoke.dart <executable> <node>',
    );
    exitCode = 64;
    return;
  }
  final executable = File(arguments[0]);
  final node = File(arguments[1]).resolveSymbolicLinksSync();
  final repository = Directory.fromUri(Platform.script.resolve('../'));
  final schema = ContractSchema(
    jsonDecode(
      File(p.join(repository.path, 'contracts/json/public-result.schema.json'))
          .readAsStringSync(),
    ),
  );
  final protocol = jsonDecode(
    File(p.join(repository.path, 'contracts/helper/request.schema.json'))
        .readAsStringSync(),
  )['properties']['protocol_version']['const'];
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-runtime-')
        .resolveSymbolicLinksSync(),
  );
  var count = 0;
  try {
    final install = Directory(p.join(base.path, 'installation café'))
      ..createSync();
    final binary = stageInstallation(executable, install);
    final helper = File(p.join(install.path, 'assets/typescript/helper.cjs'));
    final root = Directory(p.join(base.path, 'project'))..createSync();
    File(p.join(root.path, 'architecture.yaml')).writeAsStringSync('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: []
exclude: []
nodes: []
''');
    File(p.join(root.path, 'tsconfig.json')).writeAsStringSync('{"files":[]}');
    final environment = Map<String, String>.from(Platform.environment)
      ..removeWhere((key, _) => key.toUpperCase() == 'PATH')
      ..['PATH'] = p.dirname(node);
    final command = [binary.path, '--root', root.path, 'check'];
    Map validate(_Captured result, int expected) {
      check(
        result.code == expected,
        'Expected $expected, got ${result.code}: ${utf8.decode(result.out)}; ${utf8.decode(result.err)}',
      );
      check(result.err.isEmpty, 'CLI stderr is not empty');
      check(
        result.out.isNotEmpty &&
            result.out.last == 10 &&
            result.out.where((byte) => byte == 10).length == 1,
        'Expected exactly one newline-terminated public JSON report',
      );
      final value = jsonDecode(utf8.decode(result.out)) as Map;
      final errors = schema.errors(value);
      check(errors.isEmpty, 'Public schema: $errors');
      check(value['exit_code'] == expected, 'Reported exit differs');
      count++;
      return value;
    }

    Future<Map> invoke(int expected, {int seconds = 15}) async => validate(
      await capture(
        command,
        cwd: base.path,
        environment: environment,
        timeout: Duration(seconds: seconds),
      ),
      expected,
    );
    final request = jsonEncode({
      'protocol_version': protocol,
      'request_id': 'check:web',
      'project_id': 'web',
      'root_uri': root.uri.toString().replaceFirst(RegExp(r'/$'), ''),
      'config_path': 'tsconfig.json',
      'expected_files': [],
    });
    final cleanEnvironment = Map<String, String>.from(environment)
      ..removeWhere(
        (key, _) => ['NODE_', 'LD_', 'DYLD_'].any(key.toUpperCase().startsWith),
      );
    // The owned pinned-Node wrapper feeds actual stdin to the genuine helper.
    // On Windows its child inherits the outer Job; no unowned capture process.
    final captured = await capture(
      [
        node,
        '-e',
        '''
const result=require('node:child_process').spawnSync(process.execPath,[process.argv[1]],{input:process.argv[2],timeout:10000,killSignal:'SIGKILL',maxBuffer:8*1024*1024});
process.stdout.write(JSON.stringify({status:result.status,signal:result.signal,error:result.error?.message??null,out:(result.stdout??Buffer.alloc(0)).toString('base64'),err:(result.stderr??Buffer.alloc(0)).toString('base64')}));
''',
        helper.path,
        request,
      ],
      cwd: base.path,
      environment: cleanEnvironment,
    );
    check(
      captured.code == 0,
      'Genuine helper failed: ${utf8.decode(captured.err)}',
    );
    final observation = jsonDecode(utf8.decode(captured.out)) as Map;
    check(
      observation['status'] == 0 &&
          observation['signal'] == null &&
          observation['error'] == null,
      'Genuine helper failed: $observation',
    );
    final envelope = jsonDecode(
      utf8.decode(base64Decode(observation['out'] as String)),
    ) as Map;
    envelope['status'] = 'complete';
    envelope['unknowns'] = [];
    envelope['tool_errors'] = [];
    final raw = utf8.encode(jsonEncode(envelope));
    final payload = "Buffer.from('${base64Encode(raw)}','base64')";
    void canned({
      String before = '',
      String after = '',
    }) => helper.writeAsStringSync(
      "process.stdin.resume();process.stdin.on('end',()=>{$before process.stdout.write($payload);$after});",
    );
    canned();
    check(
      (await invoke(0))['payload']['analysis_complete'] == true,
      'Complete envelope rejected',
    );
    canned(
      after: 'process.stdout.end();process.stderr.end();setTimeout(()=>process.exit(9),250);',
    );
    check(
      (await invoke(
        2,
      ))['payload']['tool_errors'][0]['message'].contains('code 9'),
      'EOF accepted before nonzero exit',
    );
    for (final (suffix, expected) in [(' ', 0), ('x', 2)]) {
      final childPid = File(p.join(base.path, 'late-output-$expected.pid'));
      final done = File(p.join(base.path, 'late-output-$expected.done'));
      final child =
          "setTimeout(()=>process.stdout.write(${jsonEncode(suffix)},error=>{if(error)throw error;const fs=require('node:fs');const marker=${jsonEncode(done.path)};fs.writeFileSync(marker+'.pending',${jsonEncode(suffix)});fs.renameSync(marker+'.pending',marker);}),250)";
      canned(
        after:
            "const child=require('node:child_process').spawn(process.execPath,['-e',${jsonEncode(child)}],{detached:process.platform==='win32',stdio:['ignore',1,2]});const fs=require('node:fs');const marker=${jsonEncode(childPid.path)};fs.writeFileSync(marker+'.pending',String(child.pid));fs.renameSync(marker+'.pending',marker);child.unref();process.exit(0);",
      );
      try {
        final value = await invoke(expected);
        check(
          done.readAsStringSync() == suffix,
          'Late writer did not complete',
        );
        check(
          value['payload']['analysis_complete'] == (expected == 0),
          'Late output completion differs',
        );
      } finally {
        if (childPid.existsSync())
          terminateProcessId(int.parse(childPid.readAsStringSync()));
      }
    }
    for (final extra in [0, 1]) {
      canned(
        before:
            'process.stdout.write(Buffer.alloc(${64 * 1024 * 1024 - raw.length + extra},32));',
      );
      final value = await invoke(extra == 0 ? 0 : 2, seconds: 30);
      check(
        value['payload']['analysis_complete'] == (extra == 0),
        'stdout boundary completion differs',
      );
      if (extra == 1)
        check(
          value['payload']['tool_errors'][0]['message'].contains(
            'stdout limit',
          ),
          'Missing stdout limit diagnostic',
        );
    }
    for (final extra in [0, 1]) {
      canned(
        before:
            'process.stderr.write(Buffer.alloc(${256 * 1024 + extra},120));',
      );
      final value = await invoke(extra == 0 ? 0 : 2);
      check(
        value['payload']['analysis_complete'] == (extra == 0),
        'stderr boundary completion differs',
      );
      if (extra == 1)
        check(
          value['payload']['tool_errors'][0]['message'].contains(
            'stderr limit',
          ),
          'Missing stderr limit diagnostic',
        );
    }
    String? sender;
    if (Platform.isWindows) {
      sender = p.join(base.path, 'console-sender.exe');
      final compiled = await capture(
        [
          Platform.resolvedExecutable,
          '--suppress-analytics',
          'compile',
          'exe',
          p.join(repository.path, 'test/support/windows_console_sender.dart'),
          '-o',
          sender,
        ],
        cwd: repository.path,
        environment: Platform.environment,
        timeout: const Duration(seconds: 60),
      );
      check(
        compiled.code == 0,
        'Sender compilation failed: ${utf8.decode(compiled.err)}',
      );
    }
    final pidFile = File(p.join(base.path, 'helper.pid'));
    helper.writeAsStringSync(
      "${publishPid(pidFile)}process.stdin.resume();setInterval(()=>{},1000);",
    );
    final process = await _Child.start(
      command,
      cwd: base.path,
      environment: environment,
      interruptible: true,
    );
    var failed = false;
    try {
      final helperPid = await readyPid(pidFile);
      await process.interrupt(sender);
      final value = validate(
        await process.capture(const Duration(seconds: 5)),
        2,
      );
      check(
        (value['payload']['tool_errors'] as List).any(
          (error) =>
              (error['message'] as String).toLowerCase().contains('cancelled'),
        ),
        'Missing cancellation diagnostic',
      );
      check(
        (value['payload']['facts']['edges'] as List).isEmpty,
        'Cancellation retained unexpected edges',
      );
      check(!isProcessAlive(helperPid), 'Cancelled helper is still alive');
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      try {
        await process.close(operationFailed: failed);
      } finally {
        if (pidFile.existsSync())
          terminateProcessId(int.parse(pidFile.readAsStringSync()));
      }
    }
    pidFile.deleteSync();
    helper.writeAsStringSync(
      "${publishPid(pidFile)}process.stdin.resume();process.stdout.write($payload);setInterval(()=>{},1000);",
    );
    final elapsed = Stopwatch()..start();
    final timed = await _Child.start(
      command,
      cwd: base.path,
      environment: environment,
    );
    failed = false;
    try {
      final value = validate(
        await timed.capture(const Duration(seconds: 130)),
        2,
      );
      check(
        elapsed.elapsed >= const Duration(seconds: 119) &&
            elapsed.elapsed < const Duration(seconds: 126),
        'Production deadline elapsed ${elapsed.elapsed}',
      );
      check(
        value['payload']['tool_errors'][0]['message'].contains(
          'deadline exceeded',
        ),
        'Missing deadline diagnostic',
      );
      check(
        value['payload']['analysis_complete'] == false,
        'Deadline accepted complete frame',
      );
      check(
        !isProcessAlive(int.parse(pidFile.readAsStringSync())),
        'Timed-out helper is still alive',
      );
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      try {
        await timed.close(operationFailed: failed);
      } finally {
        if (pidFile.existsSync())
          terminateProcessId(int.parse(pidFile.readAsStringSync()));
      }
    }
    check(count == 10, 'Expected all ten original runtime scenarios');
    stdout.writeln('$count real runtime lifecycle/schema checks passed.');
  } finally {
    base.deleteSync(recursive: true);
  }
}
