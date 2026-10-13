"""Native Windows fixture-tree cleanup controls; POSIX cannot certify Win32 jobs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool/ci'))
from npm_windows_job import WindowsJob


@unittest.skipUnless(os.name == 'nt', 'Windows Job Object requires native Windows')
class WindowsJobTests(unittest.TestCase):
    def test_pre_readiness_timeout_and_malformed_marker_clean_owned_tree(self):
        for failure in ('before-readiness', 'malformed-readiness'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                witness, ready = base / 'child.pid', base / 'ready.json'
                child = "import time;time.sleep(60)"
                parent = ('import subprocess,sys,time,pathlib;'
                          f'p=subprocess.Popen([sys.executable,"-c",{child!r}]);'
                          f'w=pathlib.Path({str(witness)!r});t=w.with_suffix(".pending");'
                          't.write_text(str(p.pid));t.replace(w);')
                if failure == 'malformed-readiness':
                    parent += f'pathlib.Path({str(ready)!r}).write_text("invalid json");'
                parent += 'time.sleep(60)'
                job, process, child_handle = WindowsJob(), None, None
                try:
                    process = job.spawn([sys.executable, '-c', parent],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    deadline = time.monotonic() + 10
                    while not witness.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(witness.exists(), 'Owned descendant did not start')
                    child_handle = job.api.OpenProcess(0x100000, False, int(witness.read_text()))
                    self.assertTrue(child_handle)
                    with self.assertRaises((TimeoutError, json.JSONDecodeError)):
                        if failure == 'before-readiness':
                            self.assertFalse(ready.exists())
                            raise TimeoutError('Injected readiness deadline')
                        deadline = time.monotonic() + 5
                        while not ready.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        json.loads(ready.read_text())
                finally:
                    job.close()
                    if process is not None:
                        process.communicate(timeout=5)
                    if child_handle:
                        from ctypes import wintypes
                        job.api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
                        job.api.WaitForSingleObject.restype = wintypes.DWORD
                        try:
                            # Job termination initiates asynchronous process exits;
                            # wait on this retained descendant handle to confirm exit.
                            # https://learn.microsoft.com/windows/win32/api/jobapi2/nf-jobapi2-terminatejobobject
                            self.assertEqual(job.api.WaitForSingleObject(child_handle, 5000), 0,
                                             'Owned descendant exit unconfirmed')
                        finally:
                            job.api.CloseHandle(child_handle)
                self.assertIsNotNone(process.returncode)
                self.assertIsNone(job.handle)

    def test_assignment_and_resume_failures_reap_suspended_process(self):
        real_popen = subprocess.Popen
        for failure in ('assignment', 'resume'):
            with self.subTest(failure=failure):
                job, processes = WindowsJob(), []
                def capture(*args, **kwargs):
                    process = real_popen(*args, **kwargs)
                    processes.append(process)
                    return process
                patch = (mock.patch.object(job.api, 'AssignProcessToJobObject', return_value=0)
                         if failure == 'assignment' else
                         mock.patch.object(job, '_resume_initial_thread', side_effect=RuntimeError('resume injection')))
                with patch, mock.patch('npm_windows_job.subprocess.Popen', side_effect=capture):
                    with self.assertRaises((OSError, RuntimeError)):
                        job.spawn([sys.executable, '-c', 'import time;time.sleep(60)'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertEqual(len(processes), 1)
                self.assertIsNotNone(processes[0].returncode)
                self.assertIsNone(job.handle)


if __name__ == '__main__':
    if '--require-windows' in sys.argv:
        sys.argv.remove('--require-windows')
        if os.name != 'nt':
            raise SystemExit('Native Windows required; no skipped cleanup certification')
    unittest.main()
