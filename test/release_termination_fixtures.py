"""Synthetic termination receipts for validator tests, never execution proof."""
def termination_fixture(target, route):
    windows = target == 'windows-x64'
    cache = route == 'cache' and not windows
    signals = [('TerminateProcess', 23)] if windows else [('SIGINT', 2), ('SIGTERM', -15), ('SIGHUP', -1)]
    cases = [{'case': name, 'native_exit': code, 'route_exit': code, 'streams_equal': True,
              'core_terminated': True, 'native_helper_terminated': name == 'SIGINT',
              'route_helper_terminated': name == 'SIGINT'} for name, code in signals]
    cases.append({'case': 'unsupported-platform-selection', 'invocation': 'launcher-selection-supplement',
                  'injected_platform': 'freebsd', 'exit': 126, 'launcher_stderr_only': True})
    group = {'applicable': False, 'reason': 'windows-native-termination-control' if windows else 'not-npm-exec-route'}
    boundary = []
    if cache:
        group = {'applicable': True, 'stimulus': 'isolated-process-group-SIGINT', 'invocation': 'actual-npm-exec',
                 'outer_exit': -2, 'core_envelope_exit': 2, 'core_status': 'incomplete',
                 'core_terminated': True, 'helper_terminated': True, 'stderr': ''}
        boundary = [{'case': name, 'native_exit': code, 'status': 'FAILED', 'observation': {
            'outcome': 'termination-unconfirmed', 'outer_exit': None, 'core_pid_exists': True,
            'stdout_bytes': 0, 'stderr_bytes': 0}} for name, code in signals]
    return {'termination_control': {
        'mechanism': 'windows-native-TerminateProcess-exit-propagation' if windows else 'posix-owned-launcher-signal-forwarding',
        'invocation': 'selected-cached-shim-supplement' if cache else 'installed-route', 'cases': cases,
        'cache_group_sigint': group,
        'outer_npm_pid_observations': {'scope': 'external-outer-npm-PID-not-own-launcher', 'cases': boundary}}}
