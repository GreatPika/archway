"""Host-neutral controls for failure evidence, not native PATH acceptance."""
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
    'path_evidence_lifecycle', ROOT / 'test/windows_installer_lifecycle.py')
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)


class PathFailureEvidence(unittest.TestCase):
    def test_uninstall_mismatch_retains_exact_synthetic_path_and_owner_state(self):
        owner = r'Software\Archway\Installer'
        original = ('unrelated original PATH is not diagnostic input', 2)
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
            calls = []
            before = []
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
                else:
                    before.append(state['Environment']['Path'])
                    state['Environment']['Path'] = ('wrong synthetic PATH', 2)
                    del state[owner]
                    (root / 'unins000.exe').unlink()
                return subprocess.CompletedProcess(arguments, 0)
            with patch.object(lifecycle.sys, 'platform', 'win32'), patch.dict(
                    lifecycle.sys.modules, {'winreg': registry}), patch.dict(
                    os.environ, {'LOCALAPPDATA': temporary}):
                with self.assertRaises(AssertionError) as raised:
                    lifecycle.run_lifecycle(Path('old'), Path('new'), stale_name,
                                            run_command=execute)
            evidence = raised.exception.args[0]
            self.assertEqual(evidence['before']['path'], before[0])
            self.assertEqual(evidence['before']['owner'], {
                'Root': (str(root), 1), 'PathToken': (token, 1)})
            self.assertEqual(evidence['after'], {
                'path': ('wrong synthetic PATH', 2), 'owner': None})
            self.assertTrue(evidence['expected']['path'][0].endswith(';C:\\later unrelated 雪'))
            self.assertNotIn(token, evidence['expected']['path'][0])
            self.assertEqual(evidence['expected']['path'][1], 1)
            self.assertEqual(len(calls), 3)
            self.assertEqual(state['Environment']['Path'], original)
            self.assertNotIn(original[0], repr(evidence))


if __name__ == '__main__':
    unittest.main()
