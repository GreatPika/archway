// Owned launcher termination gates remain distinct from external npm observations.
import 'release_receipt_values.dart';

void validateNpmTermination(
  Map<String, dynamic> receipt,
  String target,
  String route,
  Object? node,
  Object? npm,
) {
  final platform = {
    'linux-x64': 'linux',
    'macos-arm64': 'darwin',
    'windows-x64': 'win32',
  }[target];
  requireReceipt(
    platform != null && ['local', 'global', 'cache'].contains(route),
    'Unknown npm target or route',
  );
  requireReceipt(
    exactReceipt(node, [
          'v24.21.0',
          platform,
          target == 'macos-arm64' ? 'arm64' : 'x64',
        ]) &&
        npm == '11.19.0',
    'npm termination runtime versions missing or inconsistent',
  );
  final windows = target == 'windows-x64',
      cache = route == 'cache' && target != 'windows-x64';
  final signals = windows
      ? {'TerminateProcess': 23}
      : {'SIGINT': 2, 'SIGTERM': -15, 'SIGHUP': -1};
  final control = receiptObject(receipt['termination_control']);
  final cases = receiptList(control['cases']);
  requireReceipt(
    cases.length == signals.length + 1,
    'Owned npm termination gates missing or failed',
  );
  final expected = <Map<String, Object?>>[];
  var index = 0;
  for (final signal in signals.entries) {
    final observed = receiptObject(cases[index++]);
    final helpers = <String, Object?>{};
    for (final field in [
      'native_helper_terminated',
      'route_helper_terminated',
    ]) {
      requireReceipt(
        observed[field] is bool,
        'Owned helper termination state is not a boolean',
      );
      helpers[field] = signal.key == 'SIGINT' ? true : observed[field];
    }
    expected.add({
      'case': signal.key,
      'native_exit': signal.value,
      'route_exit': signal.value,
      'streams_equal': true,
      'core_terminated': true,
      ...helpers,
    });
  }
  expected.add({
    'case': 'unsupported-platform-selection',
    'invocation': 'launcher-selection-supplement',
    'injected_platform': 'freebsd',
    'exit': 126,
    'launcher_stderr_only': true,
  });
  Map<String, Object?> group = {
    'applicable': false,
    'reason': windows
        ? 'windows-native-termination-control'
        : 'not-npm-exec-route',
  };
  var boundaries = <dynamic>[];
  if (cache) {
    final observed = receiptObject(control['cache_group_sigint']);
    requireReceipt(
      observed['outer_exit'] is int &&
          observed['outer_exit'] != 0 &&
          observed['stderr'] is String,
      'Actual npm-exec group cancellation did not terminate',
    );
    group = {
      'applicable': true,
      'stimulus': 'isolated-process-group-SIGINT',
      'invocation': 'actual-npm-exec',
      'outer_exit': observed['outer_exit'],
      'core_envelope_exit': 2,
      'core_status': 'incomplete',
      'core_terminated': true,
      'helper_terminated': true,
      'stderr': observed['stderr'],
    };
    boundaries = receiptList(
      receiptObject(control['outer_npm_pid_observations'])['cases'],
    );
    requireReceipt(
      boundaries.length == signals.length,
      'External npm PID observations missing',
    );
    index = 0;
    for (final signal in signals.entries) {
      final boundary = receiptObject(boundaries[index++]);
      final observation = receiptObject(boundary['observation']);
      for (final key in ['stdout_bytes', 'stderr_bytes']) {
        requireReceipt(
          observation[key] is int && (observation[key] as int) >= 0,
          'External npm observation stream size invalid',
        );
      }
      final expectedObservation = <String, Object?>{
        for (final key in ['outer_exit', 'stdout_bytes', 'stderr_bytes'])
          key: observation[key],
      };
      String status;
      if (observation.containsKey('outcome')) {
        requireReceipt(
          (observation['outer_exit'] == null ||
                  observation['outer_exit'] is int) &&
              observation['core_pid_exists'] is bool,
          'External npm live-process observation invalid',
        );
        expectedObservation.addAll({
          'outcome': 'termination-unconfirmed',
          'core_pid_exists': observation['core_pid_exists'],
        });
        status = 'FAILED';
      } else {
        requireReceipt(
          observation['outer_exit'] is int &&
              observation['streams_equal'] is bool,
          'External npm completed observation invalid',
        );
        expectedObservation.addAll({
          'core_terminated': true,
          'streams_equal': observation['streams_equal'],
        });
        status =
            observation['outer_exit'] == signal.value &&
                observation['streams_equal'] == true
            ? 'PASSED'
            : 'FAILED';
      }
      requireReceipt(
        exactReceipt(boundary, {
          'case': signal.key,
          'status': status,
          'native_exit': signal.value,
          'observation': expectedObservation,
        }),
        'External npm boundary observation inconsistent',
      );
    }
  }
  requireReceipt(
    exactReceipt(control, {
      'mechanism': windows
          ? 'windows-native-TerminateProcess-exit-propagation'
          : 'posix-owned-launcher-signal-forwarding',
      'invocation': cache
          ? 'selected-cached-shim-supplement'
          : 'installed-route',
      'cases': expected,
      'cache_group_sigint': group,
      'outer_npm_pid_observations': {
        'scope': 'external-outer-npm-PID-not-own-launcher',
        'cases': boundaries,
      },
    }),
    'Owned npm termination gates missing or failed',
  );
}
