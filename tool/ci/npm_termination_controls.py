"""Owned-process termination observations through real installed npm routes."""
import json
import os
import signal
import shutil
import subprocess
import time

from npm_local_analysis import assert_result, snapshot
from npm_probe_budgets import NPM_PREPARATION_TIMEOUT
from npm_windows_job import WindowsJob


class WindowsOwnedProcesses:
    """Handles keep fixture cleanup bound to these processes, not reused PIDs."""
    def __init__(self, pids):
        import ctypes
        from ctypes import wintypes
        self.ctypes = ctypes
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.api.TerminateProcess.restype = wintypes.BOOL
        self.api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.api.WaitForSingleObject.restype = wintypes.DWORD
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.api.CloseHandle.restype = wintypes.BOOL
        self.handles = {}
        try:
            for name, pid in pids.items():
                handle = self.api.OpenProcess(0x00100001, False, pid)  # SYNCHRONIZE | TERMINATE
                if not handle:
                    raise ctypes.WinError(ctypes.get_last_error())
                self.handles[name] = handle
        except BaseException:
            self.close()
            raise

    def terminate_core(self):
        if not self.api.TerminateProcess(self.handles['core'], 23):
            raise self.ctypes.WinError(self.ctypes.get_last_error())
        assert self.api.WaitForSingleObject(self.handles['core'], 3000) == 0

    def close(self):
        failures = []
        for name, handle in self.handles.items():
            if self.api.WaitForSingleObject(handle, 0) != 0:
                self.api.TerminateProcess(handle, 1)
                if self.api.WaitForSingleObject(handle, 3000) != 0:
                    failures.append(name)
            self.api.CloseHandle(handle)
        self.handles.clear()
        assert not failures, ('Owned Windows fixture cleanup unconfirmed', failures)


def exercise(shim, root, cwd, installed, environment, command, target, *, cache_route=False):
    binary = installed / 'bin' / target / ('archway.exe' if target == 'windows-x64' else 'archway')
    helper = installed / 'assets/typescript/helper.cjs'
    original = helper.read_bytes()
    before = snapshot(root), snapshot(cwd), snapshot(installed)
    ready = root.parent / 'npm termination ready.json'
    pending = ready.with_suffix('.pending')
    assert not ready.exists() and not pending.exists()
    windows = os.name == 'nt'
    events = ['TerminateProcess'] if windows else [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]
    cases, failures, boundary = [], [], []
    group = {'applicable': False, 'reason': 'windows-native-termination-control' if windows
             else 'not-npm-exec-route'}
    for event in events:
        observed, helper_states = {}, {}
        routes = ['route', 'native']
        if cache_route and not windows:
            routes += ['outer']
            if event == signal.SIGINT:
                routes += ['group']
        for route in routes:
            arguments = [str(binary if route == 'native' else shim), '--root', str(root), 'check']
            process, owned, job = None, None, None
            try:
                helper.write_text("const fs=require('node:fs');fs.writeFileSync(" + json.dumps(str(pending)) +
                    ",JSON.stringify({helper:process.pid,core:process.ppid}));fs.renameSync(" +
                    json.dumps(str(pending)) + ',' + json.dumps(str(ready)) +
                    " );setTimeout(()=>{},30000);",
                    encoding='utf-8')
                # Cached-shim PID parity is an explicit supplement. The outer and
                # group observations below still execute real npm exec.
                direct = route == 'native' or (cache_route and not windows and route == 'route')
                job = WindowsJob() if windows else None
                spawn = job.spawn if windows else subprocess.Popen
                process = spawn(arguments if direct else command(arguments),
                    cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=not windows)
                readiness_timeout = NPM_PREPARATION_TIMEOUT if cache_route and not direct else 15
                deadline = time.monotonic() + readiness_timeout
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert ready.exists(), 'Installed core did not reach helper-ready barrier'
                pids = json.loads(ready.read_text(encoding='utf-8'))
                assert set(pids) == {'helper', 'core'} and all(type(p) is int and p > 0 for p in pids.values())
                assert pids['helper'] != pids['core']
                if route == 'native':
                    assert pids['core'] == process.pid, 'Wrong direct-native reference process'
                if windows:
                    owned = WindowsOwnedProcesses(pids)
                    owned.terminate_core()
                elif route == 'group':
                    os.killpg(process.pid, event)
                else:
                    process.send_signal(event)
                stdout, stderr = process.communicate(timeout=5)
                if not windows:
                    required_pids = pids.values() if event == signal.SIGINT else [pids['core']]
                    for pid in required_pids:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            pass
                        else:
                            raise subprocess.TimeoutExpired(arguments, 5, output=stdout, stderr=stderr)
                if windows:
                    helper_states[route] = owned.api.WaitForSingleObject(owned.handles['helper'], 0) == 0
                else:
                    try:
                        os.kill(pids['helper'], 0)
                        helper_states[route] = False
                    except ProcessLookupError:
                        helper_states[route] = True
                observed[route] = (process.returncode, stdout, stderr)
            except subprocess.TimeoutExpired as error:
                exists = False
                if not windows:
                    try:
                        os.kill(pids['core'], 0)
                        exists = True
                    except ProcessLookupError:
                        pass
                observed[route] = {'outcome': 'termination-unconfirmed', 'outer_exit': process.poll(),
                                   'core_pid_exists': exists,
                                   'stdout_bytes': len(error.output or b''),
                                   'stderr_bytes': len(error.stderr or b'')}
            finally:
                try:
                    try:
                        if owned is not None:
                            owned.close()
                    finally:
                        try:
                            if job is not None:
                                job.close()
                        finally:
                            if process is not None:
                                if windows:
                                    if process.poll() is None:
                                        process.terminate()
                                else:
                                    # Fixture cleanup only; never a product process-tree guarantee.
                                    try:
                                        os.killpg(process.pid, signal.SIGKILL)
                                    except ProcessLookupError:
                                        pass
                                process.communicate(timeout=5)
                finally:
                    try:
                        ready.unlink(missing_ok=True)
                        pending.unlink(missing_ok=True)
                    finally:
                        helper.write_bytes(original)
        assert isinstance(observed['native'], tuple), ('Native termination unconfirmed', event, observed['native'])
        if not windows and event == signal.SIGINT:
            value = assert_result(subprocess.CompletedProcess([], *observed['native']), 2, 'incomplete')
            assert value['payload']['analysis_complete'] is False
            assert 'INSPECTION_CANCELLED' in [e['code'] for e in value['payload']['tool_errors']]
        else:
            expected = 23 if windows else -int(event)
            assert observed['native'][0] == expected, ('Unexpected native termination', event, observed)
        if 'outer' in observed:
            outer = observed['outer']
            boundary.append({'case': event.name,
                'status': 'PASSED' if outer == observed['native'] else 'FAILED',
                'native_exit': observed['native'][0],
                'observation': outer if isinstance(outer, dict) else {
                    'outer_exit': outer[0], 'stdout_bytes': len(outer[1]),
                    'stderr_bytes': len(outer[2]), 'core_terminated': True,
                    'streams_equal': outer[1:] == observed['native'][1:]}})
        if 'group' in observed:
            result = observed['group']
            assert isinstance(result, tuple), ('npm-exec group SIGINT termination unconfirmed', result)
            code, stdout, stderr = result
            assert code != 0 and stdout.endswith(b'\n') and stdout.count(b'\n') == 1
            assert not stdout.startswith(b'\xef\xbb\xbf')
            value = json.loads(stdout)
            assert (value['schema_version'], value['command'], value['exit_code'], value['status']) == (
                1, 'check', 2, 'incomplete')
            assert value['payload']['analysis_complete'] is False
            assert 'INSPECTION_CANCELLED' in [e['code'] for e in value['payload']['tool_errors']]
            group = {'applicable': True, 'stimulus': 'isolated-process-group-SIGINT',
                     'invocation': 'actual-npm-exec', 'outer_exit': code, 'core_envelope_exit': 2,
                     'core_status': 'incomplete', 'core_terminated': True, 'helper_terminated': True,
                     'stderr': stderr.decode('utf-8')}
        if observed['route'] != observed['native']:
            route_result = observed['route']
            failures.append({'case': event if windows else event.name,
                'native_exit': observed['native'][0],
                'route': route_result if isinstance(route_result, dict) else {
                    'exit': route_result[0], 'stdout_bytes': len(route_result[1]),
                    'stderr_bytes': len(route_result[2])}})
            continue
        cases.append({'case': event if windows else event.name, 'native_exit': observed['native'][0],
                      'route_exit': observed['route'][0], 'streams_equal': True, 'core_terminated': True,
                      'native_helper_terminated': helper_states['native'],
                      'route_helper_terminated': helper_states['route']})
    assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
    node = shutil.which('node', path=environment['PATH'])
    assert node is not None
    unsupported = subprocess.run([node, '-e',
        "Object.defineProperty(process,'platform',{value:'freebsd'});require(process.argv[1]);",
        str(installed / 'bin/archway.cjs')], cwd=cwd, env=environment, capture_output=True, timeout=30)
    assert unsupported.returncode == 126 and unsupported.stdout == b''
    assert unsupported.stderr.startswith(b'archway launcher: unsupported target freebsd/')
    assert (snapshot(root), snapshot(cwd), snapshot(installed)) == before
    cases.append({'case': 'unsupported-platform-selection', 'invocation': 'launcher-selection-supplement',
                  'injected_platform': 'freebsd', 'exit': 126, 'launcher_stderr_only': True})
    if failures:
        print(json.dumps({'termination_failures': failures, 'completed_controls': cases,
                          'fixture_restored': True}), flush=True)
        raise AssertionError('Installed route termination differs from native: ' + json.dumps(failures))
    return {'mechanism': 'windows-native-TerminateProcess-exit-propagation' if windows
            else 'posix-owned-launcher-signal-forwarding',
            'invocation': 'selected-cached-shim-supplement' if cache_route and not windows else 'installed-route',
            'cases': cases, 'cache_group_sigint': group,
            'outer_npm_pid_observations': {'scope': 'external-outer-npm-PID-not-own-launcher',
                                          'cases': boundary}}
