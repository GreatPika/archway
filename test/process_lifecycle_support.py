"""Real SIGINT/CTRL_C and safe process liveness on native acceptance hosts."""
import ctypes
import os
import signal
import subprocess
import sys


def start_interruptible(command, **kwargs):
    if os.name == 'nt':
        # Windows inherits this attribute independently of signal handlers.
        # Normalize the fixture harness before spawning so an ignored CTRL+C
        # from its runner shell cannot silently disable the target's handler.
        from ctypes import wintypes
        api = ctypes.WinDLL('kernel32', use_last_error=True)
        api.SetConsoleCtrlHandler.argtypes = [ctypes.c_void_p, wintypes.BOOL]
        api.SetConsoleCtrlHandler.restype = wintypes.BOOL
        if not api.SetConsoleCtrlHandler(None, False):
            raise ctypes.WinError(ctypes.get_last_error())
        # A distinct console confines GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)
        # to the fixture process and the short-lived sender attached below.
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        kwargs.update(creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=startup)
    return subprocess.Popen(command, **kwargs)


def interrupt(process):
    if os.name != 'nt':
        process.send_signal(signal.SIGINT)
        return
    # Keep the harness's console unchanged. CTRL_BREAK is NOT SIGINT: only an
    # attached console's real CTRL_C event tests the CLI's cancellation handler.
    sender = r'''
import ctypes, sys, time
from ctypes import wintypes
api = ctypes.WinDLL('kernel32', use_last_error=True)
api.FreeConsole.argtypes = []
api.FreeConsole.restype = wintypes.BOOL
api.AttachConsole.argtypes = [wintypes.DWORD]
api.AttachConsole.restype = wintypes.BOOL
api.SetConsoleCtrlHandler.argtypes = [ctypes.c_void_p, wintypes.BOOL]
api.SetConsoleCtrlHandler.restype = wintypes.BOOL
api.GenerateConsoleCtrlEvent.argtypes = [wintypes.DWORD, wintypes.DWORD]
api.GenerateConsoleCtrlEvent.restype = wintypes.BOOL
api.FreeConsole()
if not api.AttachConsole(int(sys.argv[1])):
    raise ctypes.WinError(ctypes.get_last_error())
try:
    if not api.SetConsoleCtrlHandler(None, True):
        raise ctypes.WinError(ctypes.get_last_error())
    if not api.GenerateConsoleCtrlEvent(0, 0):
        raise ctypes.WinError(ctypes.get_last_error())
    time.sleep(.2)
finally:
    api.FreeConsole()
'''
    result = subprocess.run([sys.executable, '-c', sender, str(process.pid)],
                            capture_output=True, timeout=5)
    if result.returncode:
        raise RuntimeError('Windows CTRL_C console delivery failed: ' +
                           result.stderr.decode('utf-8', errors='replace'))


def _process_handle(pid, access):
    from ctypes import wintypes
    api = ctypes.WinDLL('kernel32', use_last_error=True)
    api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    api.OpenProcess.restype = wintypes.HANDLE
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    api.CloseHandle.restype = wintypes.BOOL
    api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    api.WaitForSingleObject.restype = wintypes.DWORD
    api.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    api.TerminateProcess.restype = wintypes.BOOL
    handle = api.OpenProcess(access, False, pid)
    if not handle:
        error = ctypes.get_last_error()
        if error == 87:  # ERROR_INVALID_PARAMETER: no such PID.
            return api, None
        raise ctypes.WinError(error)
    return api, handle


def is_alive(pid):
    if os.name != 'nt':
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True
    # os.kill(pid, 0) TERMINATES a Windows process; use a wait-only handle.
    api, handle = _process_handle(pid, 0x00100000)  # SYNCHRONIZE
    if handle is None:
        return False
    try:
        state = api.WaitForSingleObject(handle, 0)
        if state == 0xFFFFFFFF:
            raise ctypes.WinError(ctypes.get_last_error())
        return state == 258  # WAIT_TIMEOUT; signalled means exited.
    finally:
        api.CloseHandle(handle)


def terminate_pid(pid):
    if os.name != 'nt':
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return
    api, handle = _process_handle(pid, 0x00100001)  # SYNCHRONIZE | PROCESS_TERMINATE
    if handle is None:
        return
    try:
        if api.WaitForSingleObject(handle, 0) == 258:
            if not api.TerminateProcess(handle, 1):
                raise ctypes.WinError(ctypes.get_last_error())
            if api.WaitForSingleObject(handle, 5000) != 0:
                raise RuntimeError(f'Fixture process {pid} did not terminate')
    finally:
        api.CloseHandle(handle)
