"""Own the Windows acceptance fixture tree before any launcher code executes."""
import subprocess
import time


class WindowsJob:
    def __init__(self):
        import ctypes
        from ctypes import wintypes as w
        self.c = c = ctypes
        self.api = a = c.WinDLL('kernel32', use_last_error=True)

        class BasicLimit(c.Structure):
            _fields_ = [('per_process', c.c_int64), ('per_job', c.c_int64),
                        ('flags', w.DWORD), ('minimum', c.c_size_t), ('maximum', c.c_size_t),
                        ('active_limit', w.DWORD), ('affinity', c.c_size_t),
                        ('priority', w.DWORD), ('scheduling', w.DWORD)]

        class IoCounters(c.Structure):
            _fields_ = [(name, c.c_uint64) for name in
                        ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]

        class ExtendedLimit(c.Structure):
            _fields_ = [('basic', BasicLimit), ('io', IoCounters),
                        ('process_memory', c.c_size_t), ('job_memory', c.c_size_t),
                        ('peak_process_memory', c.c_size_t), ('peak_job_memory', c.c_size_t)]

        class Accounting(c.Structure):
            _fields_ = [(name, c.c_int64) for name in ('user', 'kernel', 'period_user', 'period_kernel')] + [
                (name, w.DWORD) for name in ('faults', 'total', 'active', 'terminated')]

        class ThreadEntry(c.Structure):
            _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('id', w.DWORD),
                        ('owner', w.DWORD), ('base_priority', w.LONG), ('delta_priority', w.LONG),
                        ('flags', w.DWORD)]

        self.Accounting, self.ThreadEntry = Accounting, ThreadEntry
        signatures = {
            'CreateJobObjectW': ([c.c_void_p, w.LPCWSTR], w.HANDLE),
            'SetInformationJobObject': ([w.HANDLE, c.c_int, c.c_void_p, w.DWORD], w.BOOL),
            'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
            'TerminateJobObject': ([w.HANDLE, w.UINT], w.BOOL),
            'QueryInformationJobObject': ([w.HANDLE, c.c_int, c.c_void_p, w.DWORD, c.c_void_p], w.BOOL),
            'OpenProcess': ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            'CreateToolhelp32Snapshot': ([w.DWORD, w.DWORD], w.HANDLE),
            'Thread32First': ([w.HANDLE, c.POINTER(ThreadEntry)], w.BOOL),
            'Thread32Next': ([w.HANDLE, c.POINTER(ThreadEntry)], w.BOOL),
            'OpenThread': ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            'ResumeThread': ([w.HANDLE], w.DWORD),
            'CloseHandle': ([w.HANDLE], w.BOOL),
        }
        for name, (args, result) in signatures.items():
            getattr(a, name).argtypes, getattr(a, name).restype = args, result
        self.handle = a.CreateJobObjectW(None, None)
        if not self.handle:
            raise c.WinError(c.get_last_error())
        limits = ExtendedLimit()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not a.SetInformationJobObject(self.handle, 9, c.byref(limits), c.sizeof(limits)):
            error = c.WinError(c.get_last_error())
            a.CloseHandle(self.handle)
            self.handle = None
            raise error

    def spawn(self, arguments, **kwargs):
        """Assignment failure is fatal; never request breakaway from an enclosing job."""
        process = None
        try:
            process = subprocess.Popen(arguments, creationflags=0x4, **kwargs)  # CREATE_SUSPENDED
            handle = self.api.OpenProcess(0x101, False, process.pid)  # SET_QUOTA | TERMINATE
            if not handle:
                raise self.c.WinError(self.c.get_last_error())
            try:
                if not self.api.AssignProcessToJobObject(self.handle, handle):
                    raise self.c.WinError(self.c.get_last_error())
            finally:
                self.api.CloseHandle(handle)
            self._resume_initial_thread(process.pid)
            return process
        except BaseException:
            try:
                if process is not None:
                    process.kill()
                    process.communicate(timeout=5)
            finally:
                self.close()
            raise

    def _resume_initial_thread(self, pid):
        a, c = self.api, self.c
        snapshot = a.CreateToolhelp32Snapshot(4, 0)  # TH32CS_SNAPTHREAD
        if snapshot == c.c_void_p(-1).value:
            raise c.WinError(c.get_last_error())
        try:
            entry = self.ThreadEntry()
            entry.size = c.sizeof(entry)
            present = a.Thread32First(snapshot, c.byref(entry))
            threads = []
            while present:
                if entry.owner == pid:
                    threads.append(entry.id)
                present = a.Thread32Next(snapshot, c.byref(entry))
            assert len(threads) == 1, ('Expected one suspended initial thread', threads)
        finally:
            a.CloseHandle(snapshot)
        thread = a.OpenThread(2, False, threads[0])  # THREAD_SUSPEND_RESUME
        if not thread:
            raise c.WinError(c.get_last_error())
        try:
            if a.ResumeThread(thread) != 1:
                raise RuntimeError('Owned initial thread resume failed')
        finally:
            a.CloseHandle(thread)

    def close(self):
        if not self.handle:
            return
        a, c = self.api, self.c
        try:
            if not a.TerminateJobObject(self.handle, 1):
                raise c.WinError(c.get_last_error())
            deadline = time.monotonic() + 5
            while True:
                info = self.Accounting()
                if not a.QueryInformationJobObject(self.handle, 1, c.byref(info), c.sizeof(info), None):
                    raise c.WinError(c.get_last_error())
                if info.active == 0:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError('Owned Windows job cleanup unconfirmed')
                time.sleep(0.01)
        finally:
            a.CloseHandle(self.handle)
            self.handle = None
