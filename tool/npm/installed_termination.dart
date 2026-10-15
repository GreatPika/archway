// Installed thin-wrapper parity; actual npm exec and cached-shim supplements differ.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../validation/json_values.dart';
import 'installed_assets.dart';
import 'installed_termination_process.dart';

Future<Map<String, Object?>> exerciseInstalledTermination(
  NpmInstalledControls controls, {
  required File node,
  bool cacheRoute = false,
}) async {
  final helper = File(
    p.join(controls.payload.path, 'assets', 'typescript', 'helper.cjs'),
  );
  final original = helper.readAsBytesSync(), before = controls.snapshot();
  final ready = File(
    p.join(controls.project.parent.path, 'npm termination ready.json'),
  );
  final pending = File(p.setExtension(ready.path, '.pending'));
  controls.require(
    [ready, pending].every(
      (file) =>
          FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.notFound,
    ),
    'Termination readiness path occupied',
  );
  // Installed and relocated phases share the recorder; retain each observation.
  final logs = controls.recorder.output.createTempSync('termination-');
  final windows = Platform.isWindows;
  final events = windows
      ? [ProcessSignal.sigterm]
      : [ProcessSignal.sigint, ProcessSignal.sigterm, ProcessSignal.sighup];
  final cases = <Map<String, Object?>>[],
      failures = <Map<String, Object?>>[],
      boundary = <Map<String, Object?>>[];
  Map<String, Object?> group = {
    'applicable': false,
    'reason': windows
        ? 'windows-native-termination-control'
        : 'not-npm-exec-route',
  };
  bool equal(NativeProcessResult? a, NativeProcessResult? b) =>
      a != null &&
      b != null &&
      a.exitCode == b.exitCode &&
      sameJson(a.stdout, b.stdout) &&
      sameJson(a.stderr, b.stderr);
  void cancelled(NativeProcessResult result, {bool npmGroup = false}) {
    final value = controls.checkResult(
      npmGroup ? (exitCode: 2, stdout: result.stdout, stderr: <int>[]) : result,
      2,
      'incomplete',
    );
    controls.require(
      value['payload']['analysis_complete'] == false &&
          (value['payload']['tool_errors'] as List).any(
            (e) => e['code'] == 'INSPECTION_CANCELLED',
          ),
      'Expected cancelled incomplete envelope',
    );
  }

  try {
    for (final event in events) {
      final name = windows
          ? 'TerminateProcess'
          : event.toString().split('.').last.toUpperCase();
      final observed = <String, TerminationObservation>{};
      final routes = [
        'route',
        'native',
        if (cacheRoute && !windows) ...[
          'outer',
          if (event == ProcessSignal.sigint) 'group',
        ],
      ];
      for (final route in routes) {
        final args = [
          route == 'native'
              ? controls.nativeExecutable.path
              : controls.executable.path,
          '--root',
          controls.project.path,
          'check',
        ];
        final direct =
            route == 'native' || (cacheRoute && !windows && route == 'route');
        try {
          helper.writeAsStringSync(
            "const fs=require('node:fs');fs.writeFileSync(${jsonEncode(pending.path)},"
            'JSON.stringify({helper:process.pid,core:process.ppid}));'
            'fs.renameSync(${jsonEncode(pending.path)},${jsonEncode(ready.path)});setTimeout(()=>{},30000);',
          );
          observed[route] = await observeInstalledTermination(
            controls,
            direct ? args : controls.command(args),
            ready: ready,
            signal: event,
            route: route,
            readinessTimeout: Duration(
              seconds: cacheRoute && !direct ? 120 : 15,
            ),
            evidence: File(p.join(logs.path, '${name.toLowerCase()}-$route')),
          );
        } finally {
          try {
            if (ready.existsSync()) ready.deleteSync();
          } finally {
            try {
              if (pending.existsSync()) pending.deleteSync();
            } finally {
              helper.writeAsBytesSync(original);
            }
          }
        }
      }
      final native = observed['native']!.result;
      controls.require(native != null, 'Native termination unconfirmed: $name');
      if (!windows && event == ProcessSignal.sigint)
        cancelled(native!);
      else
        controls.require(
          native!.exitCode == (windows ? 23 : -event.signalNumber),
          'Unexpected native termination: $name',
        );
      if (observed['outer'] case final outer?) {
        boundary.add({
          'case': name,
          'status': equal(outer.result, native) ? 'PASSED' : 'FAILED',
          'native_exit': native.exitCode,
          'observation':
              outer.unconfirmed ??
              {
                'outer_exit': outer.result!.exitCode,
                'stdout_bytes': outer.result!.stdout.length,
                'stderr_bytes': outer.result!.stderr.length,
                'core_terminated': true,
                'streams_equal':
                    sameJson(outer.result!.stdout, native.stdout) &&
                    sameJson(outer.result!.stderr, native.stderr),
              },
        });
      }
      if (observed['group'] case final groupObservation?) {
        final result = groupObservation.result;
        controls.require(
          result != null && result.exitCode != 0,
          'npm-exec group SIGINT termination unconfirmed',
        );
        cancelled(result!, npmGroup: true);
        group = {
          'applicable': true,
          'stimulus': 'isolated-process-group-SIGINT',
          'invocation': 'actual-npm-exec',
          'outer_exit': result.exitCode,
          'core_envelope_exit': 2,
          'core_status': 'incomplete',
          'core_terminated': true,
          'helper_terminated': true,
          'stderr': utf8.decode(result.stderr),
        };
      }
      final route = observed['route']!;
      if (!equal(route.result, native)) {
        failures.add({
          'case': name,
          'native_exit': native.exitCode,
          'route':
              route.unconfirmed ??
              {
                'exit': route.result!.exitCode,
                'stdout_bytes': route.result!.stdout.length,
                'stderr_bytes': route.result!.stderr.length,
              },
        });
      } else {
        cases.add({
          'case': name,
          'native_exit': native.exitCode,
          'route_exit': route.result!.exitCode,
          'streams_equal': true,
          'core_terminated': true,
          'native_helper_terminated': observed['native']!.helperTerminated,
          'route_helper_terminated': route.helperTerminated,
        });
      }
    }
    controls.unchanged(before);
    final unsupported = await controls.recorder.capture(
      [
        node.path,
        '-e',
        "Object.defineProperty(process,'platform',{value:'freebsd'});require(process.argv[1]);",
        p.join(controls.wrapper.path, 'bin', 'archway.cjs'),
      ],
      workingDirectory: controls.cwd.path,
      environment: controls.environment,
      expectedExit: 126,
    );
    controls.require(
      unsupported.stdout.isEmpty &&
          utf8
              .decode(unsupported.stderr)
              .startsWith('archway launcher: unsupported target freebsd/'),
      'Unexpected unsupported-platform selection',
    );
    controls.unchanged(before);
    cases.add({
      'case': 'unsupported-platform-selection',
      'invocation': 'launcher-selection-supplement',
      'injected_platform': 'freebsd',
      'exit': 126,
      'launcher_stderr_only': true,
    });
    if (failures.isNotEmpty) {
      File(p.join(logs.path, 'failures.json')).writeAsStringSync(
        '${jsonEncode({'termination_failures': failures, 'completed_controls': cases, 'fixture_restored': true})}\n',
      );
      throw StateError(
        'Installed route termination differs from native: ${jsonEncode(failures)}',
      );
    }
    return {
      'mechanism': windows
          ? 'windows-native-TerminateProcess-exit-propagation'
          : 'posix-owned-launcher-signal-forwarding',
      'invocation': cacheRoute && !windows
          ? 'selected-cached-shim-supplement'
          : 'installed-route',
      'cases': cases,
      'cache_group_sigint': group,
      'outer_npm_pid_observations': {
        'scope': 'external-outer-npm-PID-not-own-launcher',
        'cases': boundary,
      },
    };
  } finally {
    controls.unchanged(before);
  }
}
