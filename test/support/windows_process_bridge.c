// Developer-only process fixture bridge; never linked into the product ABI.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

__declspec(dllexport) BOOL archway_create_process(
    LPCWSTR application, LPWSTR command, LPSECURITY_ATTRIBUTES process_security,
    LPSECURITY_ATTRIBUTES thread_security, BOOL inherit, DWORD flags,
    LPVOID environment, LPCWSTR directory, LPSTARTUPINFOW startup,
    LPPROCESS_INFORMATION information, DWORD *error) {
  BOOL result = CreateProcessW(application, command, process_security,
      thread_security, inherit, flags, environment, directory, startup,
      information);
  // No Dart transition or other Win32 operation may precede this capture.
  *error = result ? ERROR_SUCCESS : GetLastError();
  return result;
}
