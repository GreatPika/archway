// Synthetic summaries describe the documented owned/external termination split.
Map<String, dynamic> terminationFixture(String target, String route) {
  final windows = target == 'windows-x64',
      cache = route == 'cache' && target != 'windows-x64';
  final signals = windows
      ? {'TerminateProcess': 23}
      : {'SIGINT': 2, 'SIGTERM': -15, 'SIGHUP': -1};
  return {
    'termination_control': {
      'mechanism': windows
          ? 'windows-native-TerminateProcess-exit-propagation'
          : 'posix-owned-launcher-signal-forwarding',
      'invocation': cache
          ? 'selected-cached-shim-supplement'
          : 'installed-route',
      'cases': [
        for (final signal in signals.entries)
          {
            'case': signal.key,
            'native_exit': signal.value,
            'route_exit': signal.value,
            'streams_equal': true,
            'core_terminated': true,
            'native_helper_terminated': signal.key == 'SIGINT',
            'route_helper_terminated': signal.key == 'SIGINT',
          },
        {
          'case': 'unsupported-platform-selection',
          'invocation': 'launcher-selection-supplement',
          'injected_platform': 'freebsd',
          'exit': 126,
          'launcher_stderr_only': true,
        },
      ],
      'cache_group_sigint': cache
          ? {
              'applicable': true,
              'stimulus': 'isolated-process-group-SIGINT',
              'invocation': 'actual-npm-exec',
              'outer_exit': -2,
              'core_envelope_exit': 2,
              'core_status': 'incomplete',
              'core_terminated': true,
              'helper_terminated': true,
              'stderr': '',
            }
          : {
              'applicable': false,
              'reason': windows
                  ? 'windows-native-termination-control'
                  : 'not-npm-exec-route',
            },
      'outer_npm_pid_observations': {
        'scope': 'external-outer-npm-PID-not-own-launcher',
        'cases': [
          if (cache)
            for (final signal in signals.entries)
              {
                'case': signal.key,
                'native_exit': signal.value,
                'status': 'FAILED',
                'observation': {
                  'outcome': 'termination-unconfirmed',
                  'outer_exit': null,
                  'core_pid_exists': true,
                  'stdout_bytes': 0,
                  'stderr_bytes': 0,
                },
              },
        ],
      },
    },
  };
}
