"""Host-neutral lifecycle completion controls; no native acceptance claimed."""
from contextlib import nullcontext
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'completion_lifecycle', ROOT / 'test/windows_installer_lifecycle.py')
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


class UninstallCompletion(unittest.TestCase):
    def run_case(self, mode):
        owner = r'Software\Archway\Installer'
        original = ('original test-account PATH', 1)
        state = {'Environment': {'Path': original}}
        registry = Mock(REG_SZ=1, REG_EXPAND_SZ=2)
        def open_key(_, name):
            if name not in state:
                raise FileNotFoundError(name)
            return nullcontext(name)
        def query(key, name):
            if name not in state[key]:
                raise FileNotFoundError(name)
            return state[key][name]
        registry.OpenKey.side_effect = open_key
        registry.CreateKey.side_effect = open_key
        registry.QueryValueEx.side_effect = query
        registry.SetValueEx.side_effect = lambda key, name, _, kind, value: state[key].update(
            {name: (value, kind)})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'Programs/Archway'
            token = str(root / 'bin/windows-x64')
            stale_name = 'obsolete/installer-probe..txt'
            calls, sleeps = [], []
            def execute(arguments, **_):
                calls.append(arguments)
                if len(calls) == 1:
                    (root / 'obsolete').mkdir(parents=True)
                    (root / stale_name).write_bytes(b'old fixture')
                    (root / 'unins000.exe').write_bytes(b'fixture')
                    (root / 'manifest.json').write_text(json.dumps({'files': {stale_name: {}}}))
                    raw, kind = state['Environment']['Path']
                    state['Environment']['Path'] = (raw + ';' + token, kind)
                    state[owner] = {'Root': (str(root), 1), 'PathToken': (token, 1)}
                elif len(calls) == 2:
                    (root / stale_name).unlink()
                    (root / 'manifest.json').write_text('{"files":{}}')
                    if mode == 'missing-owner':
                        del state[owner]['Root']
                elif len(calls) == 3:
                    raw, kind = state['Environment']['Path']
                    state['Environment']['Path'] = (raw.replace(';' + token, ''), kind)
                    del state[owner]['PathToken']
                    # Inno first phase exits while second phase retains its EXE.
                    if mode == 'failed-exit':
                        return subprocess.CompletedProcess(arguments, 1)
                    if mode == 'timeout-owner':
                        (root / 'unins000.exe').unlink()
                    if mode == 'timeout-exe':
                        del state[owner]
                    if mode == 'foreign':
                        (root / 'foreign-leftover.txt').write_text('must survive')
                else:
                    self.assertFalse(root.exists())
                    raise RuntimeError('reached next installation boundary')
                return subprocess.CompletedProcess(arguments, 0)
            def complete_second_phase(delay):
                sleeps.append(delay)
                (root / 'unins000.exe').unlink()
                (root / 'manifest.json').unlink()
                (root / 'obsolete').rmdir()
                del state[owner]
            with patch.object(lifecycle.sys, 'platform', 'win32'), patch.dict(
                    lifecycle.sys.modules, {'winreg': registry}), patch.dict(
                    os.environ, {'LOCALAPPDATA': temporary}), patch(
                    'time.sleep', side_effect=complete_second_phase), patch(
                    'time.monotonic', side_effect=[0, 180] if mode.startswith('timeout') else None,
                    return_value=0):
                error = {'complete': RuntimeError, 'timeout': TimeoutError, 'foreign': OSError,
                         'failed-exit': AssertionError, 'missing-owner': AssertionError,
                         'timeout-owner': TimeoutError, 'timeout-exe': TimeoutError}[mode]
                with self.assertRaises(error) as raised:
                    lifecycle.run_lifecycle(Path('old'), Path('new'), stale_name,
                                            run_command=execute)
            self.assertEqual(state['Environment']['Path'], original)
            if mode == 'complete':
                self.assertIn('next installation boundary', str(raised.exception))
                self.assertEqual((len(calls), len(sleeps)), (4, 1))
            elif mode.startswith('timeout'):
                self.assertIn('Inno uninstall did not complete', str(raised.exception))
                self.assertEqual((len(calls), len(sleeps)), (3, 0))
                self.assertEqual((root / 'unins000.exe').exists(), mode != 'timeout-owner')
                self.assertEqual(owner in state, mode != 'timeout-exe')
            elif mode == 'foreign':
                self.assertEqual((len(calls), len(sleeps)), (3, 1))
                self.assertEqual((root / 'foreign-leftover.txt').read_text(), 'must survive')
            elif mode == 'failed-exit':
                self.assertEqual(raised.exception.args[0], 1)
                self.assertEqual(len(sleeps), 0)
            else:
                self.assertIn('unverified installer ownership', str(raised.exception))
                self.assertEqual((len(calls), len(sleeps)), (2, 0))

    def test_waits_for_second_phase_before_assertions_and_next_install(self):
        self.run_case('complete')

    def test_uncompleted_second_phase_times_out_without_relaunch(self):
        self.run_case('timeout')

    def test_remaining_owner_marker_alone_prevents_completion(self):
        self.run_case('timeout-owner')

    def test_remaining_uninstaller_alone_prevents_completion(self):
        self.run_case('timeout-exe')

    def test_foreign_leftover_still_fails_strict_root_removal(self):
        self.run_case('foreign')

    def test_failed_uninstaller_exit_never_enters_completion_wait(self):
        self.run_case('failed-exit')

    def test_preexisting_missing_owner_cannot_satisfy_completion(self):
        self.run_case('missing-owner')


if __name__ == '__main__':
    unittest.main()
