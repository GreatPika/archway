import ctypes
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import unittest
from types import SimpleNamespace
from unittest import mock

import process_lifecycle_support as support

from process_lifecycle_support import start_interruptible, interrupt, is_alive, terminate_pid


class LifecycleSupportTest(unittest.TestCase):
    def test_windows_launch_enables_ctrl_c_before_spawn(self):
        calls = []
        api = mock.Mock()
        api.SetConsoleCtrlHandler.side_effect = lambda *args: calls.append(('enable', args)) or 1
        with mock.patch.object(support, 'os', SimpleNamespace(name='nt')), \
             mock.patch.object(ctypes, 'WinDLL', return_value=api, create=True), \
             mock.patch.multiple(subprocess, create=True, STARTUPINFO=lambda: SimpleNamespace(dwFlags=0),
                                 STARTF_USESHOWWINDOW=1, SW_HIDE=0, CREATE_NEW_CONSOLE=16), \
             mock.patch.object(subprocess, 'Popen', side_effect=lambda *a, **k: calls.append(('spawn', a))):
            start_interruptible(['fixture'])
        self.assertEqual(calls, [('enable', (None, False)), ('spawn', (['fixture'],))])

    def test_real_ctrl_c_reports_and_exits(self):
        if os.name == 'nt':
            # Reproduce the inherited Windows attribute independently of the
            # runner shell. Registering a Python SIGINT handler does not clear it.
            from ctypes import wintypes
            api = ctypes.WinDLL('kernel32', use_last_error=True)
            api.SetConsoleCtrlHandler.argtypes = [ctypes.c_void_p, wintypes.BOOL]
            api.SetConsoleCtrlHandler.restype = wintypes.BOOL
            if not api.SetConsoleCtrlHandler(None, True):
                raise ctypes.WinError(ctypes.get_last_error())
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / 'ready'
            script = ("import signal,sys,time; from pathlib import Path; "
                      "signal.signal(signal.SIGINT, lambda *_: sys.exit(23)); "
                      f"Path({str(marker)!r}).touch(); time.sleep(60)")
            process = start_interruptible([sys.executable, '-c', script],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(marker.exists())
                self.assertTrue(is_alive(process.pid))
                interrupt(process)
                process.communicate(timeout=10)
                self.assertEqual(process.returncode, 23)
                self.assertFalse(is_alive(process.pid))
            finally:
                if process.poll() is None:
                    terminate_pid(process.pid)
                    process.wait(timeout=5)

    def test_live_probe_does_not_terminate_process(self):
        process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        try:
            self.assertTrue(is_alive(process.pid))
            self.assertIsNone(process.poll())
            terminate_pid(process.pid)
            process.wait(timeout=5)
            self.assertFalse(is_alive(process.pid))
            terminate_pid(process.pid)  # Already gone is safe cleanup.
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == '__main__':
    unittest.main()
