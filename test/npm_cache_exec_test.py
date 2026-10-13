"""Bounded cache-route controls; fixtures are not native npm-exec acceptance."""
from pathlib import Path
import tempfile
import os
import subprocess
import json
from unittest import mock
import sys
import unittest
import types

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
import npm_cache_exec as cache
import npm_termination_controls as termination
import npm_installed_acceptance as acceptance


class CacheExecTests(unittest.TestCase):
    def test_init_subprocess_deadline_is_cache_specific(self):
        for route, expected in [('local', 30), ('global', 30), ('cache', 120)]:
            with self.subTest(route=route), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp).resolve()
                project, foreign, installed = [base / name for name in ['project', 'foreign', 'installed']]
                for directory in [project, foreign, installed]: directory.mkdir()
                shim = installed / 'shim'
                shim.touch()
                (installed / 'manifest.json').write_bytes(b'{}')
                (installed / 'package.json').write_text(json.dumps({'name': acceptance.PACKAGE,
                    'version': '0.1.0', 'bin': {'archway': 'bin/archway.cjs'}}))
                evidence = {'manifest_sha256': acceptance.digest(installed / 'manifest.json')}
                def checked(arguments, *args):
                    value = b'archway [--root ROOT] COMMAND\n' if arguments[-1] == '--help' else b'archway 0.1.0\n'
                    return subprocess.CompletedProcess(arguments, 0, value, b'')
                def stopped(arguments, **kwargs):
                    self.assertEqual(kwargs['timeout'], expected)
                    raise RuntimeError('stop at subprocess boundary')
                with mock.patch.object(subprocess, 'run', side_effect=stopped):
                    with self.assertRaisesRegex(RuntimeError, 'stop at subprocess boundary'):
                        acceptance.accept_installation(shim, project, foreign, installed, installed,
                            evidence, base / 'init', {}, checked, lambda args: args,
                            target='linux-x64', cache_route=route == 'cache')

    def test_readiness_and_post_stimulus_deadlines_cover_each_termination_route(self):
        # Earlier routes reach their marker and finish; the selected route stops
        # at either readiness or its first (post-stimulus) communicate boundary.
        cases = [(True, True, ['route', 'native'], [120, 15]),
                 (True, False, ['route', 'native'], [15, 15]),
                 (False, True, ['route', 'native', 'outer', 'group'], [15, 15, 120, 120]),
                 (False, False, ['route', 'native'], [15, 15])]
        for windows, cache_route, routes, deadlines in cases:
            for selected, route in enumerate(routes):
                for phase in ['readiness', 'observation']:
                    with self.subTest(windows=windows, cache=cache_route, route=route, phase=phase), \
                            tempfile.TemporaryDirectory() as tmp:
                        base = Path(tmp).resolve()
                        root, cwd, installed = [base / name for name in ['root', 'cwd', 'installed']]
                        for directory in [root, cwd, installed]: directory.mkdir()
                        helper = installed / 'assets/typescript/helper.cjs'
                        helper.parent.mkdir(parents=True)
                        helper.write_bytes(b'original')
                        ready = base / 'npm termination ready.json'
                        clock, processes, observations = [0.0], [], []
                        def spawn(arguments, **kwargs):
                            index = len(processes)
                            self.assertLessEqual(index, selected)
                            process = mock.Mock(pid=777 + index, returncode=23 if windows else -2)
                            process.poll.return_value = None
                            calls = []
                            has_marker = index < selected or phase == 'observation'
                            if has_marker:
                                ready.write_text(json.dumps({'core': process.pid, 'helper': 888 + index}))
                            def communicate(*, timeout):
                                calls.append(timeout)
                                if has_marker and len(calls) == 1:
                                    observations.append((index, timeout))
                                    if index == selected:
                                        raise RuntimeError('stop after termination stimulus')
                                return b'', b''
                            process.communicate.side_effect = communicate
                            processes.append(process)
                            return process
                        job = mock.Mock()
                        job.spawn.side_effect = spawn
                        owned = mock.Mock(handles={'core': 777, 'helper': 888})
                        owned.api.WaitForSingleObject.return_value = 0
                        def sleep(seconds): clock[0] += seconds
                        with mock.patch.object(termination, 'os', types.SimpleNamespace(
                                name='nt' if windows else 'posix', killpg=mock.Mock(),
                                kill=mock.Mock(side_effect=ProcessLookupError))), \
                             mock.patch.object(termination, 'WindowsJob', return_value=job), \
                             mock.patch.object(termination, 'WindowsOwnedProcesses', return_value=owned), \
                             mock.patch.object(termination.subprocess, 'Popen', side_effect=spawn), \
                             mock.patch.object(termination.time, 'monotonic', side_effect=lambda: clock[0]), \
                             mock.patch.object(termination.time, 'sleep', side_effect=sleep):
                            error = AssertionError if phase == 'readiness' else RuntimeError
                            message = 'helper-ready barrier' if phase == 'readiness' else 'stop after termination stimulus'
                            with self.assertRaisesRegex(error, message):
                                termination.exercise(base / 'shim', root, cwd, installed, {}, lambda args: args,
                                    'windows-x64' if windows else 'linux-x64', cache_route=cache_route)
                        self.assertEqual(len(processes), selected + 1)
                        observed_count = selected if phase == 'readiness' else selected + 1
                        self.assertEqual(observations, [(index, 5) for index in range(observed_count)])
                        if phase == 'readiness':
                            self.assertGreaterEqual(clock[0], deadlines[selected])
                            self.assertLess(clock[0], deadlines[selected] + .03)
                            processes[-1].communicate.assert_called_once_with(timeout=5)  # Cleanup only.
                        else:
                            self.assertEqual(clock[0], 0)
                            self.assertEqual(processes[-1].communicate.call_args_list,
                                             [mock.call(timeout=5), mock.call(timeout=5)])
                        if windows: self.assertEqual(job.close.call_count, selected + 1)
                        self.assertEqual(helper.read_bytes(), b'original')
                        self.assertFalse(ready.exists())

    def test_rejects_locator_fallback_outside_requested_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            owned_cache = base / 'cache ü'
            package = base / 'global/node_modules/archway-architecture-cli'
            package.mkdir(parents=True)
            shim = base / 'global/node_modules/.bin/archway.cmd'
            shim.parent.mkdir()
            shim.write_text('fixture')
            node = base / 'node'
            node.write_text('fixture')
            wrong_node = base / 'wrong node/node'
            wrong_node.parent.mkdir(); wrong_node.write_bytes(b'wrong runtime fixture')
            value = {'shim': str(shim), 'installed': str(package), 'node': str(node),
                     'version': 'v24.21.0', 'dart': None}
            with self.assertRaisesRegex(AssertionError, 'requested cache'):
                cache.bind_selection(value, owned_cache, node)

    def test_cached_binary_is_restored_when_exec_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary)
            binary = package / 'bin/linux-x64/archway'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'original binary')
            def fail(expected_exit):
                self.assertFalse(binary.exists())
                raise RuntimeError('npm exec failed')
            with self.assertRaisesRegex(RuntimeError, 'npm exec failed'):
                cache.payload_control(package, 'linux-x64', fail)
            self.assertEqual(binary.read_bytes(), b'original binary')
            self.assertEqual(list(binary.parent.iterdir()), [binary])

    def test_binds_only_selected_cache_package_and_pinned_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            owned_cache = base / 'cache ü'
            package = owned_cache / '_npx/abc/node_modules/archway-architecture-cli'
            package.mkdir(parents=True)
            shim = package.parent / '.bin/archway.cmd'
            shim.parent.mkdir()
            shim.write_text('fixture')
            node = base / 'node'
            node.write_text('fixture')
            wrong_node = base / 'wrong node/node'
            wrong_node.parent.mkdir(); wrong_node.write_bytes(b'wrong runtime fixture')
            value = {'shim': str(shim), 'installed': str(package), 'node': str(node),
                     'version': 'v24.21.0', 'dart': None}
            self.assertEqual(cache.bind_selection(value, owned_cache, node), (shim, package))
            for key, changed in [('dart', '/unexpected/dart'), ('version', 'v0.0.0'),
                                 ('node', '/other/node'), ('installed', str(package.parent))]:
                with self.subTest(key=key), self.assertRaises(AssertionError):
                    cache.bind_selection({**value, key: changed}, owned_cache, node)

    def test_payload_control_requires_launcher_failure_and_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary)
            binary = package / 'bin/linux-x64/archway'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'original binary')
            outcomes = [(126, b'', b'archway launcher: missing payload\n'),
                        (0, b'archway [--root ROOT] COMMAND\n', b'')]
            requested = []
            def run(expected_exit):
                requested.append(expected_exit)
                code, stdout, stderr = outcomes.pop(0)
                self.assertEqual(binary.exists(), code == 0)
                return subprocess.CompletedProcess([], code, stdout, stderr)
            report = cache.payload_control(package, 'linux-x64', run)
            self.assertEqual(requested, [126, 0])
            self.assertEqual(report['missing_payload_exit'], 126)
            self.assertEqual(report['recovered_help'], 0)
            self.assertEqual(binary.read_bytes(), b'original binary')

    def test_payload_control_rejects_false_success_and_still_restores(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary)
            binary = package / 'bin/windows-x64/archway.exe'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'original binary')
            with self.assertRaises(AssertionError):
                cache.payload_control(package, 'windows-x64',
                    lambda expected: subprocess.CompletedProcess([], 0, b'fake success', b''))
            self.assertEqual(binary.read_bytes(), b'original binary')

    def test_shared_acceptance_keeps_npm_exec_and_restores_helper_on_spawn_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            owned_cache = base / 'cache ü'
            project, foreign = base / 'project café', base / 'foreign ü'
            project.mkdir(); foreign.mkdir()
            node, npm, archive = base / 'node', base / 'npm', base / 'package.tgz'
            node.write_text('fixture')
            wrong_node = base / 'wrong node/node'
            wrong_node.parent.mkdir(); wrong_node.write_bytes(b'wrong runtime fixture')
            installed = owned_cache / '_npx/abc/node_modules/archway-architecture-cli'
            shim = installed.parent / '.bin/archway.cmd'
            binary = installed / 'bin/linux-x64/archway'
            helper = installed / 'assets/typescript/helper.cjs'
            bridge = installed / 'native/linux-x64/libarchway_io.so'
            prefix = [str(npm), 'exec', '--ignore-scripts', '--offline', '--yes',
                      '--package=' + str(archive), '--']
            exits = [0, 1, 64, 2, 0, 2, 2, 2, 2, 2]
            errors = ['TYPESCRIPT_ASSETS_UNAVAILABLE', 'TYPESCRIPT_ASSETS_UNAVAILABLE',
                      'TYPESCRIPT_HELPER_FAILED', 'TYPESCRIPT_ASSETS_UNAVAILABLE',
                      'TYPESCRIPT_ASSETS_UNAVAILABLE', 'TYPESCRIPT_LOAD_FAILED']
            invoked = []
            def require_exec(arguments):
                self.assertEqual(arguments[:len(prefix)], prefix)
                invoked.append(arguments[len(prefix):])
                return arguments
            def completed(arguments, code, value):
                return subprocess.CompletedProcess(arguments, code, (json.dumps(value) + '\n').encode(), b'')
            def parity_result(arguments, operands):
                if operands[0] == 'validate':
                    return completed(arguments, 0, {'command': 'validate', 'exit_code': 0, 'status': 'ok'})
                code = 64 if operands[0].startswith('unknown;') else 0
                return subprocess.CompletedProcess(arguments, code,
                    ('native parity ' + repr(operands)).encode(), b'')
            def run(arguments, cwd, environment, timeout=30, expected_exit=0):
                self.assertEqual(timeout, 120, 'Every tarball exec repeats npm preparation')
                require_exec(arguments)
                args = arguments[len(prefix):]
                if args[0] == 'node':
                    installed.mkdir(parents=True); shim.parent.mkdir()
                    shim.write_text('fixture')
                    (installed / 'package.json').write_text(json.dumps({
                        'name': 'archway-architecture-cli', 'version': '0.1.0', 'bin': {'archway': 'bin/archway.cjs'}}))
                    (installed / 'manifest.json').write_bytes(b'{}')
                    binary.parent.mkdir(parents=True); binary.write_bytes(b'owned binary')
                    bridge.parent.mkdir(parents=True); bridge.write_bytes(b'owned bridge')
                    helper.parent.mkdir(parents=True); helper.write_bytes(b'owned helper')
                    compiler = installed / 'assets/typescript/vendor/typescript/lib/typescript.js'
                    compiler.parent.mkdir(parents=True); compiler.write_bytes(b'owned compiler')
                    return completed(arguments, 0, {'shim': str(shim), 'installed': str(installed),
                        'node': str(node), 'version': 'v24.21.0', 'dart': None, 'path': str(shim.parent)})
                self.assertEqual(args[0], 'archway')
                if environment['PATH'] == str(project.parent / 'missing node runtime'):
                    return subprocess.CompletedProcess(arguments, 127, b'', b'node unavailable')
                if args[1] == '--help':
                    manifest = installed / 'manifest.json'
                    healthy = (binary.is_file() and not binary.is_symlink()
                               and binary.read_bytes() == b'owned binary'
                               and manifest.is_file() and not manifest.is_symlink()
                               and manifest.read_bytes() == b'{}')
                    return subprocess.CompletedProcess(arguments, 0 if healthy else 126,
                        b'archway [--root ROOT] COMMAND\n' if healthy else b'',
                        b'' if healthy else b'archway launcher: invalid payload\n')
                if args[1] == '--version':
                    return subprocess.CompletedProcess(arguments, 0, b'archway 0.1.0\n', b'')
                if environment['PATH'] == str(wrong_node.parent):
                    return completed(arguments, 2, {'command': 'check', 'schema_version': 1,
                        'exit_code': 2, 'status': 'incomplete', 'payload': {'analysis_complete': False,
                        'tool_errors': [{'code': 'NODE_UNAVAILABLE'}]}})
                if '--out' in args:
                    if bridge.exists():
                        (Path(args[2]) / args[-1]).write_bytes(parity_result(arguments,
                            ['export', '--format', 'mermaid']).stdout)
                        return subprocess.CompletedProcess(arguments, 0, b'', b'')
                    value = {'command': 'export', 'exit_code': 2, 'status': 'error',
                             'diagnostics': [{'code': 'EXPORT_WRITE_FAILED'}]}
                    return subprocess.CompletedProcess(arguments, 2, b'', (json.dumps(value) + '\n').encode())
                if args[3] != 'check':
                    return parity_result(arguments, args[3:])
                code = exits.pop(0)
                payload = None if code == 64 else {'policy_valid': True, 'analysis_complete': code != 2,
                    'violations': [{'code': 'DEPENDENCY_NOT_ALLOWED'}] if code == 1 else [],
                    'tool_errors': [{'code': errors.pop(0)}] if code == 2 else [],
                    'unknowns': [], 'observed': {'files': 2, 'analyzed_files': 2, 'edges': 1 if code == 1 else 0}}
                return completed(arguments, code, {'command': 'check', 'schema_version': 1, 'exit_code': code,
                    'status': {0: 'ok', 1: 'negative', 64: 'usage_error', 2: 'incomplete'}[code],
                    'payload': payload, 'tool_versions': {'typescript': '5.9.3'}})
            def init(arguments, **kwargs):
                if arguments[0] == str(wrong_node):
                    return completed(arguments, 0, ['v24.19.0', 'linux', 'x64'])
                if arguments[0] == str(binary):
                    if arguments[3:] == ['check']:
                        return completed(arguments, 2, {'command': 'check', 'schema_version': 1,
                            'exit_code': 2, 'status': 'incomplete', 'payload': {'analysis_complete': False,
                            'tool_errors': [{'code': 'NODE_UNAVAILABLE'}]}})
                    return parity_result(arguments, arguments[3:])
                self.assertEqual(arguments[:len(prefix)], prefix)
                args = arguments[len(prefix):]
                self.assertEqual(args[0], 'archway')
                self.assertEqual(kwargs['timeout'], 120, 'Cache init includes npm preparation')
                self.assertEqual(args[3:], ['init', '--template', 'mixed'])
                root = Path(args[2])
                (root / 'architecture.yaml').write_bytes(b'# Archway: mixed template\nversion: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
                (root / 'ARCHITECTURE_AGENT.md').write_text('# Architecture agent workflow\n'
                    'Init never overwrites or merges files.\nInit does not edit AGENTS.md, CI, or editor settings.\n')
                return completed(arguments, 0, {'schema_version': 1, 'command': 'init', 'status': 'ok',
                    'exit_code': 0, 'diagnostics': [], 'payload': {'template': 'mixed', 'dry_run': False,
                    'outcome': 'created', 'planned_paths': ['architecture.yaml', 'ARCHITECTURE_AGENT.md'],
                    'planned_files': [], 'created_paths': ['architecture.yaml', 'ARCHITECTURE_AGENT.md'],
                    'residual_paths': [], 'conflicting_paths': []}})
            def interrupted_spawn(arguments, **kwargs):
                # Explicit cached-shim supplement, not an npm-exec route claim.
                expected = [str(shim), '--root', str(project), 'check']
                if os.name == 'nt':
                    expected = cache.exec_arguments(npm, archive, ['archway', *expected[1:]])
                self.assertEqual(arguments, expected)
                raise RuntimeError('Owned spawn fixture stopped')
            with mock.patch('subprocess.run', side_effect=init), mock.patch(
                    'subprocess.Popen', side_effect=interrupted_spawn):
                with self.assertRaisesRegex(RuntimeError, 'Owned spawn fixture stopped'):
                    cache.exercise_cache(base, archive,
                        {'manifest_sha256': '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'},
                        'linux-x64', node, npm, project, foreign,
                        {'PATH': str(base / 'empty runtime'), 'npm_config_cache': str(owned_cache)},
                        run, require_exec, wrong_node=wrong_node)
            self.assertEqual(helper.read_bytes(), b'owned helper')
            self.assertFalse((project.parent / 'npm termination ready.json').exists())
            self.assertEqual(exits, [])
            self.assertEqual(errors, [])
            self.assertEqual(len(invoked), 31 if os.name == 'nt' else 30)

    def test_every_cache_command_keeps_offline_package_selection(self):
        self.assertEqual(cache.exec_arguments(Path('/pinned node/npm'), Path('/packed/package.tgz'),
                                             ['archway', '--root', '/project café', 'check']),
            ['/pinned node/npm', 'exec', '--ignore-scripts', '--offline', '--yes',
             '--package=/packed/package.tgz', '--', 'archway', '--root', '/project café', 'check'])


if __name__ == '__main__':
    unittest.main()
