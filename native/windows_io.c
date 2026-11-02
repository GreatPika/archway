// Windows implementation checkpoint: native writes and residual observation.
// Relative symlinks and local NT-drive symlinks/junctions are supported.
// Other absolute forms remain fail-closed pending separate target evidence.
#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#define WIN32_NO_STATUS
#include <windows.h>
#undef WIN32_NO_STATUS
#include <ntstatus.h>
#include <winternl.h>
#include <winioctl.h>
#include "io.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static archway_io_result ok(uint64_t value) {
  return (archway_io_result){value, 0, ARCHWAY_OK};
}
static archway_io_result unsupported(void) {
  return (archway_io_result){0, 0, ARCHWAY_UNSUPPORTED_ENTRY};
}
static archway_io_result invalid(void) {
  return (archway_io_result){0, 0, ARCHWAY_OTHER};
}
static archway_io_result win32_failed(DWORD error) {
  uint32_t category = ARCHWAY_OTHER;
  if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
    category = ARCHWAY_MISSING;
  else if (error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS)
    category = ARCHWAY_EXISTS;
  return (archway_io_result){0, error, category | (ARCHWAY_WIN32 << 16)};
}
static archway_io_result nt_failed(NTSTATUS status) {
  uint32_t category = ARCHWAY_OTHER;
  if (status == STATUS_OBJECT_NAME_NOT_FOUND || status == STATUS_OBJECT_PATH_NOT_FOUND)
    category = ARCHWAY_MISSING;
  else if (status == STATUS_OBJECT_NAME_COLLISION) category = ARCHWAY_EXISTS;
  return (archway_io_result){0, (uint32_t)status, category | (ARCHWAY_NTSTATUS << 16)};
}
static HANDLE handle(uint64_t value) { return (HANDLE)(uintptr_t)value; }
static int child(const char *name) {
  return name && *name && !strpbrk(name, "\\/:") &&
      strcmp(name, ".") && strcmp(name, "..");
}
// Strict UTF-8 conversion. Capture its error before freeing any allocation.
static archway_io_result wide(const char *path, WCHAR **result) {
  if (!path) return invalid();
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (!length) return win32_failed(GetLastError());
  WCHAR *buffer = malloc((size_t)length * sizeof(WCHAR));
  if (!buffer) return win32_failed(ERROR_NOT_ENOUGH_MEMORY);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, buffer, length)) {
    archway_io_result error = win32_failed(GetLastError());
    free(buffer);
    return error;
  }
  *result = buffer;
  return ok((uint64_t)(length - 1));
}
static archway_io_result validate(HANDLE file, int directory) {
  FILE_ATTRIBUTE_TAG_INFO attributes;
  if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo,
                                    &attributes, sizeof(attributes)))
    return win32_failed(GetLastError());
  if ((attributes.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      !!(attributes.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directory)
    return unsupported();
  SetLastError(ERROR_SUCCESS);
  DWORD type = GetFileType(file);
  if (type == FILE_TYPE_UNKNOWN && GetLastError() != ERROR_SUCCESS)
    return win32_failed(GetLastError());
  return type == FILE_TYPE_DISK ? ok((uint64_t)(uintptr_t)file) : unsupported();
}
static archway_io_result validated(HANDLE file, int directory) {
  archway_io_result result = validate(file, directory);
  if (result.status != ARCHWAY_OK) (void)CloseHandle(file);
  return result;
}

int32_t archway_io_version(void) { return 2; }
void *archway_io_alloc(uint64_t size) { return malloc((size_t)size); }
void archway_io_free(void *pointer) { free(pointer); }

archway_io_result archway_io_open_root(const char *path) {
  // Root is already canonicalized by its owner. Reject relative/device paths.
  if (!path || !((strlen(path) >= 3 &&
      ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) &&
      path[1] == ':' && path[2] == '\\') ||
      (strncmp(path, "\\\\", 2) == 0 && path[2] && path[2] != '.' && path[2] != '?')))
    return invalid();
  WCHAR *name = NULL;
  archway_io_result converted = wide(path, &name);
  if (converted.status != ARCHWAY_OK) return converted;
  HANDLE file = CreateFileW(name, FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  DWORD error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  free(name);
  if (file == INVALID_HANDLE_VALUE) return win32_failed(error);
  return validated(file, 1);
}
archway_io_result archway_io_open_output(uint64_t parent, const char *name, uint32_t mode) {
  if (!child(name) || mode > ARCHWAY_OVERWRITE) return invalid();
  WCHAR *text = NULL;
  archway_io_result converted = wide(name, &text);
  if (converted.status != ARCHWAY_OK) return converted;
  if (converted.value > (USHRT_MAX / sizeof(WCHAR)) - 1) {
    free(text);
    return invalid();
  }
  UNICODE_STRING relative = {
    (USHORT)(converted.value * sizeof(WCHAR)),
    (USHORT)((converted.value + 1) * sizeof(WCHAR)), text
  };
  OBJECT_ATTRIBUTES attributes = {0};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = handle(parent);
  attributes.ObjectName = &relative;
  attributes.Attributes = OBJ_CASE_INSENSITIVE; // No OBJ_INHERIT.
  IO_STATUS_BLOCK io;
  HANDLE file = NULL;
  NTSTATUS status = NtCreateFile(&file, FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      &attributes, &io, NULL, FILE_ATTRIBUTE_NORMAL,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      mode == ARCHWAY_EXCLUSIVE ? FILE_CREATE : FILE_OPEN_IF,
      FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
      NULL, 0);
  free(text);
  if (status < 0) return nt_failed(status);
  archway_io_result result = validated(file, 0);
  if (result.status != ARCHWAY_OK) return result;
  if (mode == ARCHWAY_OVERWRITE) {
    // FILE_OPEN_IF did not truncate. Only the exact ordinary, non-reparse file
    // handle validated above can now be truncated and transferred for writing.
    FILE_END_OF_FILE_INFO end = {0};
    if (!SetFileInformationByHandle(file, FileEndOfFileInfo, &end, sizeof(end))) {
      result = win32_failed(GetLastError());
      (void)CloseHandle(file);
      return result;
    }
  }
  return result;
}
archway_io_result archway_io_write(uint64_t value, const void *bytes, uint64_t length) {
  DWORD written = 0;
  DWORD count = length > MAXDWORD ? MAXDWORD : (DWORD)length;
  if (!WriteFile(handle(value), bytes, count, &written, NULL))
    return win32_failed(GetLastError());
  return ok(written);
}
archway_io_result archway_io_flush(uint64_t value) {
  return FlushFileBuffers(handle(value)) ? ok(0) : win32_failed(GetLastError());
}
archway_io_result archway_io_close(uint64_t value) {
  // Ownership is consumed by this one attempt, even when closing fails.
  return CloseHandle(handle(value)) ? ok(0) : win32_failed(GetLastError());
}
archway_io_result archway_io_open_child_directory(uint64_t parent, const char *name) {
  if (!child(name)) return invalid();
  WCHAR *text = NULL;
  archway_io_result converted = wide(name, &text);
  if (converted.status != ARCHWAY_OK) return converted;
  if (converted.value > (USHRT_MAX / sizeof(WCHAR)) - 1) {
    free(text);
    return invalid();
  }
  UNICODE_STRING relative = {
    (USHORT)(converted.value * sizeof(WCHAR)),
    (USHORT)((converted.value + 1) * sizeof(WCHAR)), text
  };
  OBJECT_ATTRIBUTES attributes = {0};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = handle(parent);
  attributes.ObjectName = &relative;
  attributes.Attributes = OBJ_CASE_INSENSITIVE;
  IO_STATUS_BLOCK io;
  HANDLE file = NULL;
  NTSTATUS status = NtCreateFile(&file,
      FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      &attributes, &io, NULL, 0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
      NULL, 0);
  free(text);
  if (status < 0) return nt_failed(status);
  // Transfer only the validated directory handle; a rejected reparse point is
  // closed once by validated(), with its primary error retained.
  return validated(file, 1);
}
archway_io_result archway_io_observe_child(uint64_t parent, const char *name) {
  if (!child(name)) return invalid();
  WCHAR *text = NULL;
  archway_io_result converted = wide(name, &text);
  if (converted.status != ARCHWAY_OK) return converted;
  if (converted.value > (USHRT_MAX / sizeof(WCHAR)) - 1) {
    free(text);
    return invalid();
  }
  UNICODE_STRING relative = {
    (USHORT)(converted.value * sizeof(WCHAR)),
    (USHORT)((converted.value + 1) * sizeof(WCHAR)), text
  };
  OBJECT_ATTRIBUTES attributes = {0};
  attributes.Length = sizeof(attributes);
  attributes.RootDirectory = handle(parent);
  attributes.ObjectName = &relative;
  attributes.Attributes = OBJ_CASE_INSENSITIVE;
  IO_STATUS_BLOCK io;
  HANDLE file = NULL;
  // Open the entry itself, of any type, without following its reparse target.
  // Permission/I/O failures remain uncertain; only actual absence is missing.
  NTSTATUS status = NtCreateFile(&file, FILE_READ_ATTRIBUTES | SYNCHRONIZE,
      &attributes, &io, NULL, 0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN,
      FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT, NULL, 0);
  free(text);
  if (status < 0) return nt_failed(status);
  // This temporary handle is never transferred. Consume it once, and preserve
  // a close failure as uncertainty rather than claiming all resources released.
  if (!CloseHandle(file)) return win32_failed(GetLastError());
  return ok(1);
}
// User-mode SDKs do not expose the WDK REPARSE_DATA_BUFFER type. This is its
// documented symlink/junction layout, bounded by the maximum reparse payload.
// https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer
struct reparse_data {
  ULONG tag;
  USHORT data_length, reserved;
  USHORT substitute_offset, substitute_length, print_offset, print_length;
  union {
    struct {
      ULONG flags;
      WCHAR path[(MAXIMUM_REPARSE_DATA_BUFFER_SIZE - 20) / sizeof(WCHAR)];
    } symlink;
    WCHAR junction[(MAXIMUM_REPARSE_DATA_BUFFER_SIZE - 16) / sizeof(WCHAR)];
  } names;
};
_Static_assert(offsetof(struct reparse_data, names.symlink.path) == 20,
               "Invalid symlink layout");
_Static_assert(offsetof(struct reparse_data, names.junction) == 16,
               "Invalid junction layout");
_Static_assert(sizeof(struct reparse_data) == MAXIMUM_REPARSE_DATA_BUFFER_SIZE,
               "Invalid reparse buffer size");
static int counted_name(USHORT offset, USHORT length, uint32_t available) {
  return !(offset & 1) && !(length & 1) && offset <= available &&
      length <= available - offset;
}
archway_io_result archway_io_read_alias(const char *path, void *bytes, uint64_t capacity) {
  if (!bytes || !capacity) return invalid();
  WCHAR *name = NULL;
  archway_io_result converted = wide(path, &name);
  if (converted.status != ARCHWAY_OK) return converted;
  HANDLE file = CreateFileW(name, 0,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  DWORD error = file == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  free(name);
  if (file == INVALID_HANDLE_VALUE) return win32_failed(error);
  struct reparse_data data;
  DWORD received = 0;
  if (!DeviceIoControl(file, FSCTL_GET_REPARSE_POINT, NULL, 0,
                       &data, sizeof(data), &received, NULL)) {
    archway_io_result failed = win32_failed(GetLastError());
    (void)CloseHandle(file);
    return failed;
  }
  if (!CloseHandle(file)) return win32_failed(GetLastError());
  if (received < 16 || received > sizeof(data) ||
      (uint32_t)data.data_length + 8 != received)
    return unsupported();
  const WCHAR *names;
  uint32_t available;
  int absolute;
  if (data.tag == IO_REPARSE_TAG_SYMLINK) {
    if (data.data_length < 12 || data.names.symlink.flags > 1)
      return unsupported(); // Only SYMLINK_FLAG_RELATIVE is defined.
    names = data.names.symlink.path;
    available = (uint32_t)data.data_length - 12;
    absolute = data.names.symlink.flags == 0;
  } else if (data.tag == IO_REPARSE_TAG_MOUNT_POINT) {
    if (data.data_length < 8) return unsupported();
    names = data.names.junction;
    available = (uint32_t)data.data_length - 8;
    absolute = 1; // Junctions carry no flags and require a local NT-drive target.
  } else {
    return unsupported();
  }
  if ((available & 1) || !data.substitute_length ||
      !counted_name(data.substitute_offset, data.substitute_length, available) ||
      !counted_name(data.print_offset, data.print_length, available))
    return unsupported();
  // Validate both counted UTF-16 fields; neither is assumed NUL-terminated.
  if (data.print_length && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      names + data.print_offset / sizeof(WCHAR),
      (int)(data.print_length / sizeof(WCHAR)), NULL, 0, NULL, NULL))
    return win32_failed(GetLastError());
  const WCHAR *target = names + data.substitute_offset / sizeof(WCHAR);
  int characters = (int)(data.substitute_length / sizeof(WCHAR));
  // Embedded NUL cannot represent a filesystem target. Do not silently shorten.
  for (int i = 0; i < characters; ++i) if (!target[i]) return unsupported();
  if (absolute) {
    // Match Node 24.21 libuv's NT-drive rewrite, never PrintName or arbitrary
    // namespace stripping. Other absolute forms are a separate target gate.
    if (characters < 6 || target[0] != L'\\' || target[1] != L'?' ||
        target[2] != L'?' || target[3] != L'\\' ||
        !((target[4] >= L'A' && target[4] <= L'Z') ||
          (target[4] >= L'a' && target[4] <= L'z')) ||
        target[5] != L':' || (characters > 6 && target[6] != L'\\'))
      return unsupported();
    target += 4;
    characters -= 4;
  }
  // Strict counted conversion preserves BOM and rejects malformed surrogates.
  int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, target,
                                  characters, NULL, 0, NULL, NULL);
  if (!needed) return win32_failed(GetLastError());
  if ((uint64_t)needed >= capacity)
    return (archway_io_result){0, 0, ARCHWAY_BUFFER_TOO_SMALL};
  int written = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, target,
                                   characters, bytes, needed, NULL, NULL);
  if (!written) return win32_failed(GetLastError());
  return ok((uint64_t)written);
}
