"""Keep owned termination gates separate from observed external npm limitations."""


def exact(actual, expected, label):
    # JSON equality alone treats true as 1, including exit codes and live-process flags.
    if type(actual) is not type(expected):
        raise ValueError(label)
    if isinstance(expected, dict):
        if actual.keys() != expected.keys():
            raise ValueError(label)
        for key in expected:
            exact(actual[key], expected[key], label)
    elif isinstance(expected, list):
        if len(actual) != len(expected):
            raise ValueError(label)
        for left, right in zip(actual, expected):
            exact(left, right, label)
    elif actual != expected:
        raise ValueError(label)


def validate_npm_termination(case, target, route, node, npm):
    platform, arch = {'linux-x64': ('linux', 'x64'), 'macos-arm64': ('darwin', 'arm64'),
                      'windows-x64': ('win32', 'x64')}[target]
    if node != ['v24.21.0', platform, arch] or npm != '11.19.0':
        raise ValueError('npm termination runtime versions missing or inconsistent')
    windows = target == 'windows-x64'
    cache = route == 'cache' and not windows
    signals = [('TerminateProcess', 23)] if windows else [('SIGINT', 2), ('SIGTERM', -15), ('SIGHUP', -1)]
    expected_cases = [{'case': name, 'native_exit': code, 'route_exit': code,
                       'streams_equal': True, 'core_terminated': True} for name, code in signals]
    expected_cases.append({'case': 'unsupported-platform-selection', 'invocation': 'launcher-selection-supplement',
                          'injected_platform': 'freebsd', 'exit': 126, 'launcher_stderr_only': True})
    control = case['termination_control']
    for observed, expected in zip(control['cases'], expected_cases[:-1]):
        for field in ('native_helper_terminated', 'route_helper_terminated'):
            if type(observed[field]) is not bool:
                raise ValueError('Owned helper termination state is not a boolean')
            expected[field] = True if expected['case'] == 'SIGINT' else observed[field]
    group = {'applicable': False, 'reason': 'windows-native-termination-control' if windows else 'not-npm-exec-route'}
    boundaries = []
    if cache:
        observed = control['cache_group_sigint']
        if type(observed['outer_exit']) is not int or observed['outer_exit'] == 0 or not isinstance(observed['stderr'], str):
            raise ValueError('Actual npm-exec group cancellation did not terminate')
        group = {'applicable': True, 'stimulus': 'isolated-process-group-SIGINT', 'invocation': 'actual-npm-exec',
                 'outer_exit': observed['outer_exit'], 'core_envelope_exit': 2, 'core_status': 'incomplete',
                 'core_terminated': True, 'helper_terminated': True, 'stderr': observed['stderr']}
        boundaries = control['outer_npm_pid_observations']['cases']
        if len(boundaries) != len(signals):
            raise ValueError('External npm PID observations missing')
        for boundary, (name, code) in zip(boundaries, signals):
            observation = boundary['observation']
            for key in ('stdout_bytes', 'stderr_bytes'):
                if type(observation[key]) is not int or observation[key] < 0:
                    raise ValueError('External npm observation stream size invalid')
            expected_observation = {key: observation[key] for key in ('outer_exit', 'stdout_bytes', 'stderr_bytes')}
            if 'outcome' in observation:
                if observation['outer_exit'] is not None and type(observation['outer_exit']) is not int:
                    raise ValueError('External npm observed exit invalid')
                if type(observation['core_pid_exists']) is not bool:
                    raise ValueError('External npm live-process observation invalid')
                expected_observation.update(outcome='termination-unconfirmed', core_pid_exists=observation['core_pid_exists'])
                status = 'FAILED'
            else:
                if type(observation['outer_exit']) is not int or type(observation['streams_equal']) is not bool:
                    raise ValueError('External npm completed observation invalid')
                expected_observation.update(core_terminated=True, streams_equal=observation['streams_equal'])
                status = 'PASSED' if observation['outer_exit'] == code and observation['streams_equal'] else 'FAILED'
            exact(boundary, {'case': name, 'status': status, 'native_exit': code,
                             'observation': expected_observation}, 'External npm boundary observation inconsistent')
    exact(control, {'mechanism': 'windows-native-TerminateProcess-exit-propagation' if windows
                    else 'posix-owned-launcher-signal-forwarding',
                    'invocation': 'selected-cached-shim-supplement' if cache else 'installed-route',
                    'cases': expected_cases, 'cache_group_sigint': group,
                    'outer_npm_pid_observations': {'scope': 'external-outer-npm-PID-not-own-launcher', 'cases': boundaries}},
          'Owned npm termination gates missing or failed')
