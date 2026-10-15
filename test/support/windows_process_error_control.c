// Regression: the saved error must survive later changes to thread LastError.
#include "windows_process_bridge.c"

__declspec(dllexport) DWORD archway_error_capture_control(LPCWSTR absent) {
  STARTUPINFOW startup = {0};
  PROCESS_INFORMATION information = {0};
  DWORD captured = 0;
  startup.cb = sizeof(startup);
  BOOL result = archway_create_process(absent, NULL, NULL, NULL, FALSE,
      CREATE_SUSPENDED, NULL, NULL, &startup, &information, &captured);
  if (result) {
    TerminateProcess(information.hProcess, 1);
    WaitForSingleObject(information.hProcess, 5000);
    CloseHandle(information.hThread);
    CloseHandle(information.hProcess);
    return 0xffffffff;
  }
  SetLastError(1234);
  if (GetLastError() != 1234) return 0xffffffff;
  return captured;
}
