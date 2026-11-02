import 'dart:async';
import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/policy_definition.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture;

void main() {
  test(
    'unconfirmed cleanup is explicit and blocks later runtime launches',
    () async {
      final root = await dartFixture(policy: _twoProjects);
      var launches = 0;
      final stuck = _ProcessFault();
      final watch = Stopwatch()..start();
      final report = await Inspection(
        startProcess:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              launches++;

              scheduleMicrotask(
                () => stuck.errors.add(List.filled(256 * 1024 + 1, 0)),
              );
              return stuck;
            },
      ).check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.exitCode, 2);
      expect(report.payload['analysis_complete'], false);
      expect((report.payload['facts'] as Map)['edges'], isEmpty);
      expect(
        (report.payload['tool_errors'] as List).map((e) => e['code']),
        contains('RUNTIME_CLEANUP_UNCONFIRMED'),
      );
      expect(
        launches,
        1,
        reason: 'one failed Dart preflight, no later launches',
      );
      expect(stuck.killed, true);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    },
  );
  test(
    'completed cancellation remains effective across reused checks',
    () async {
      final root = await dartFixture();
      var launches = 0;
      final inspection = Inspection(
        cancelled: Future.value(),
        startProcess:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              launches++;
              throw StateError('must not launch');
            },
      );
      for (var i = 0; i < 2; i++) {
        final report = await inspection.check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        expect(report.toolVersions['dart_sdk'], isNull);
        expect(
          (report.payload['tool_errors'] as List).any(
            (e) => e['message'].contains('cancelled'),
          ),
          true,
        );
      }
      expect(launches, 0);
    },
  );

  test(
    'cancellation cannot report a clean check even with no runtime needed',
    () async {
      final root = await dartFixture(
        policy: 'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
      final report = await Inspection(cancelled: Future.value())
          .check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(report.payload['analysis_complete'], false);
      expect(report.toolVersions.values, everyElement(isNull));
      expect(
        (report.payload['tool_errors'] as List).map((e) => e['code']),
        contains('INSPECTION_CANCELLED'),
      );
    },
  );

  for (final fault in [
    'stdout',
    'stderr',
    'stdin',
    'stdin async',
    'kill throws',
  ]) {
    test(
      '$fault preflight failure is bounded, reaped, and a later check can recover',
      () async {
        final root = await dartFixture(policy: _twoProjects);
        var launches = 0;
        final failed = _ProcessFault()
          ..throwOnKill = fault == 'kill throws'
          ..brokenInput = switch (fault) {
            'stdin' => _FailingSink(),
            'stdin async' => _AsyncFailingSink(),
            _ => null,
          };
        final inspection = Inspection(
          startProcess:
              (
                executable,
                arguments, {
                required workingDirectory,
                required environment,
              }) async {
                launches++;
                if (launches > 1) {
                  return Process.start(
                    executable,
                    arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    includeParentEnvironment: false,
                  );
                }
                Timer(const Duration(milliseconds: 10), () {
                  (fault == 'stdout' ? failed.output : failed.errors).addError(
                    const FileSystemException('injected pipe read failure'),
                  );
                  Timer(
                    const Duration(milliseconds: 50),
                    () => failed.exited.complete(0),
                  );
                });
                return failed;
              },
        );
        final report = await inspection.check(RepositorySelection(root.path));
        expect(report.status, 'incomplete');
        expect(launches, 1);
        expect(failed.killed, true);
        if (fault == 'stdin' || fault == 'stdin async') {
          expect(
            (report.payload['tool_errors'] as List).map((e) => e['message']),
            contains(
              contains(
                fault == 'stdin'
                    ? 'injected stdin failure'
                    : 'injected asynchronous stdin failure',
              ),
            ),
          );
        }
        expect(
          (report.payload['tool_errors'] as List).map((e) => e['code']),
          isNot(contains('RUNTIME_CLEANUP_UNCONFIRMED')),
        );
        final recoveryRoot = await dartFixture();
        final recovered = await inspection.check(
          RepositorySelection(recoveryRoot.path),
        );
        expect(launches, 2);
        expect(recovered.status, 'negative');
        expect(recovered.payload['analysis_complete'], true);
      },
    );
  }

  test(
    'confirmed preflight exit is distinguished from stalled stdin disposal',
    () async {
      final root = await dartFixture(policy: _twoProjects);
      final failed = _ProcessFault()..brokenInput = _HangingCloseSink();
      var launches = 0;
      final report = await Inspection(
        startProcess:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) async {
              launches++;

              Timer(
                const Duration(milliseconds: 10),
                () => failed.exited.complete(9),
              );
              return failed;
            },
      ).check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(launches, 1);
      expect(
        (report.payload['tool_errors'] as List).map((e) => e['code']),
        isNot(contains('RUNTIME_CLEANUP_UNCONFIRMED')),
      );
    },
  );

  test(
    'a synchronous Dart spawn rejection allows a later check to recover',
    () async {
      final root = await dartFixture();
      var launches = 0;
      final inspection = Inspection(
        startProcess:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) {
              launches++;
              if (launches == 1) {
                throw const ProcessException(
                  'dart',
                  [],
                  'injected startup failure',
                );
              }
              return Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: false,
              );
            },
      );
      final failed = await inspection.check(RepositorySelection(root.path));
      expect(failed.status, 'incomplete');
      expect(failed.toolVersions['dart_sdk'], isNull);
      expect((failed.payload['facts'] as Map)['edges'], isEmpty);
      expect(
        (failed.payload['tool_errors'] as List).map((e) => e['code']),
        isNot(contains('RUNTIME_CLEANUP_UNCONFIRMED')),
      );
      final recovered = await inspection.check(RepositorySelection(root.path));
      expect(launches, 2);
      expect(recovered.status, 'negative');
      expect(recovered.toolVersions['dart_sdk'], '3.13.3');
      expect((recovered.payload['facts'] as Map)['edges'], hasLength(1));
    },
  );

  test('an unreaped preflight leaves all Dart projects incomplete without relaunch', () async {
    final root = await dartFixture(policy: _twoProjects);
    final failed = _ProcessFault();
    var launches = 0;
    final report = await Inspection(
      startProcess:
          (
            executable,
            arguments, {
            required workingDirectory,
            required environment,
          }) async {
            launches++;
            scheduleMicrotask(() => failed.errors.add(List.filled(65537, 0)));
            return failed;
          },
    ).check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    expect(launches, 1);
    expect(report.toolVersions['dart_sdk'], isNull);
    expect(
      (report.payload['tool_errors'] as List).map((e) => e['code']),
      contains('RUNTIME_CLEANUP_UNCONFIRMED'),
    );
  });

  test(
    'a cancelled pending spawn is bounded and late arrival is killed',
    () async {
      final root = await dartFixture(policy: _twoProjects);
      final cancelled = Completer<void>();
      final pending = Completer<Process>();
      final late = _ProcessFault();
      var launches = 0;
      final watch = Stopwatch()..start();
      final report = await Inspection(
        cancelled: cancelled.future,
        startProcess:
            (
              executable,
              arguments, {
              required workingDirectory,
              required environment,
            }) {
              launches++;
              scheduleMicrotask(cancelled.complete);
              return pending.future;
            },
      ).check(RepositorySelection(root.path));
      expect(report.status, 'incomplete');
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(launches, 1);
      expect(
        (report.payload['tool_errors'] as List).map((e) => e['code']),
        contains('RUNTIME_CLEANUP_UNCONFIRMED'),
      );
      pending.complete(late);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(late.killCount, 1);
      late.exited.complete(0);
    },
  );
}

const _twoProjects = '''version: 1
projects:
  - {id: first, adapter: dart, package_roots: [./]}
  - {id: second, adapter: dart, package_roots: [./]}
scope: [lib/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [lib/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [lib/core/], allows: [], public: []}
''';

// A never-reaped process cannot be induced reliably with real SIGKILL on Linux.
// Inject only the OS boundary; assertions remain at Inspection.check.
class _ProcessFault implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final input = StreamController<List<int>>();
  final exited = Completer<int>();
  late final IOSink sink = IOSink(input.sink);
  IOSink? brokenInput;
  bool killed = false;
  bool throwOnKill = false;
  int killCount = 0;
  _ProcessFault() {
    input.stream.listen((_) {});
  }
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  IOSink get stdin => brokenInput ?? sink;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 12345;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    killCount++;
    if (throwOnKill) throw StateError('kill refused');
    return false;
  }
}

class _FailingSink implements IOSink {
  @override
  void add(List<int> data) => throw StateError('injected stdin failure');
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HangingCloseSink extends _FailingSink {
  final closed = Completer<void>();
  @override
  void add(List<int> data) {}
  @override
  Future<void> close() => closed.future;
}

class _AsyncFailingSink extends _FailingSink {
  @override
  void add(List<int> data) {}
  @override
  Future<void> close() =>
      Future.error(StateError('injected asynchronous stdin failure'));
}
