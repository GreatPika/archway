// Test-only Win32/NT syscall substitutions around the real Windows bridge.
// Production has no fault switch. CLI output and files remain the oracle.
#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#define WIN32_NO_STATUS
#include <windows.h>
#undef WIN32_NO_STATUS
#include <ntstatus.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL WINAPI fixture_write(HANDLE, LPCVOID, DWORD, LPDWORD, LPOVERLAPPED);
static BOOL WINAPI fixture_flush(HANDLE);
static BOOL WINAPI fixture_close(HANDLE);
static BOOL WINAPI fixture_information(HANDLE, FILE_INFO_BY_HANDLE_CLASS, LPVOID, DWORD);
static BOOL WINAPI fixture_ioctl(HANDLE, DWORD, LPVOID, DWORD, LPVOID, DWORD, LPDWORD, LPOVERLAPPED);
static NTSTATUS NTAPI fixture_create(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
    PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
#define WriteFile fixture_write
#define FlushFileBuffers fixture_flush
#define CloseHandle fixture_close
#define GetFileInformationByHandleEx fixture_information
#define DeviceIoControl fixture_ioctl
#define NtCreateFile fixture_create
#include "windows_io.c"
#undef WriteFile
#undef FlushFileBuffers
#undef CloseHandle
#undef GetFileInformationByHandleEx
#undef DeviceIoControl
#undef NtCreateFile

static int is_fault(const char *name) {
  const char *fault = getenv("ARCHWAY_TEST_FAULT");
  return fault && strcmp(fault, name) == 0;
}
// Track only output handles. Observation opens its own read-only handle and
// must not be confused with ownership transferred to the Dart caller.
static HANDLE outputs[64];
static int output_count;
static NTSTATUS NTAPI fixture_create(PHANDLE file, ACCESS_MASK access,
    POBJECT_ATTRIBUTES attributes, PIO_STATUS_BLOCK io, PLARGE_INTEGER allocation,
    ULONG file_attributes, ULONG share, ULONG disposition, ULONG options,
    PVOID ea, ULONG ea_length) {
  if (is_fault("observe") && access == (FILE_READ_ATTRIBUTES | SYNCHRONIZE))
    return STATUS_ACCESS_DENIED;
  NTSTATUS status = NtCreateFile(file, access, attributes, io, allocation,
      file_attributes, share, disposition, options, ea, ea_length);
  if (status >= 0 && (access & FILE_WRITE_DATA) && (options & FILE_NON_DIRECTORY_FILE)) {
    if (output_count >= 64) abort();
    outputs[output_count++] = *file;
  }
  return status;
}
static BOOL WINAPI fixture_write(HANDLE file, LPCVOID bytes, DWORD length,
                                LPDWORD written, LPOVERLAPPED overlapped) {
  if (is_fault("aborted") || is_fault("observe")) {
    SetLastError(is_fault("aborted") ? ERROR_OPERATION_ABORTED : ERROR_WRITE_FAULT);
    return FALSE;
  }
  if (is_fault("zero")) { *written = 0; return TRUE; }
  if (is_fault("partial") && length > 1) length /= 2;
  return WriteFile(file, bytes, length, written, overlapped);
}
static BOOL WINAPI fixture_flush(HANDLE file) {
  if (is_fault("flush")) { SetLastError(ERROR_WRITE_FAULT); return FALSE; }
  return FlushFileBuffers(file);
}
static BOOL WINAPI fixture_close(HANDLE file) {
  FILE_ATTRIBUTE_TAG_INFO info;
  int directory = GetFileInformationByHandleEx(file, FileAttributeTagInfo,
      &info, sizeof(info)) && (info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY);
  int output = 0;
  for (int i = 0; i < output_count; ++i) {
    if (outputs[i] == file) {
      output = 1;
      outputs[i] = outputs[--output_count];
      break;
    }
  }
  BOOL result = CloseHandle(file); // Ownership is genuinely consumed first.
  DWORD error = GetLastError();
  if ((output || directory || !result) && !is_fault("alias_invalid")) {
    const char *path = getenv("ARCHWAY_TEST_CLOSE_LOG");
    FILE *log = path ? fopen(path, "a") : NULL;
    if (log) {
      fprintf(log, "%s\n", directory ? "directory" : output ? "file" : "invalid");
      fclose(log);
    }
  }
  if (output && is_fault("close")) { SetLastError(ERROR_INVALID_HANDLE); return FALSE; }
  SetLastError(error);
  return result;
}
static BOOL WINAPI fixture_information(HANDLE file, FILE_INFO_BY_HANDLE_CLASS kind,
                                      LPVOID info, DWORD size) {
  BOOL result = GetFileInformationByHandleEx(file, kind, info, size);
  if (result && kind == FileAttributeTagInfo && is_fault("validate") &&
      !(((FILE_ATTRIBUTE_TAG_INFO *)info)->FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
    SetLastError(ERROR_ACCESS_DENIED);
    return FALSE;
  }
  return result;
}
static BOOL WINAPI fixture_ioctl(HANDLE file, DWORD code, LPVOID input, DWORD input_size,
                                LPVOID output, DWORD output_size, LPDWORD received,
                                LPOVERLAPPED overlapped) {
  if (is_fault("alias_invalid")) { SetLastError(ERROR_INVALID_REPARSE_DATA); return FALSE; }
  return DeviceIoControl(file, code, input, input_size, output, output_size, received, overlapped);
}
