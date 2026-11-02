#ifndef ARCHWAY_IO_H
#define ARCHWAY_IO_H
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define ARCHWAY_API __declspec(dllexport)
#else
#define ARCHWAY_API __attribute__((visibility("default")))
#endif

// Private ABI v2. Handles are opaque; zero can be valid. Failure transfers no
// handle. close consumes ownership even on failure and must never be retried.
typedef struct {
  uint64_t value;
  uint32_t native_error;
  uint32_t status; // category | (native domain << 16)
} archway_io_result;
enum archway_io_category {
  ARCHWAY_OK = 0, ARCHWAY_MISSING = 1, ARCHWAY_EXISTS = 2,
  ARCHWAY_INTERRUPTED = 3, ARCHWAY_BUFFER_TOO_SMALL = 4,
  ARCHWAY_UNSUPPORTED_ENTRY = 5, ARCHWAY_OTHER = 6
};
enum archway_io_domain {
  ARCHWAY_NONE = 0, ARCHWAY_POSIX = 1, ARCHWAY_WIN32 = 2, ARCHWAY_NTSTATUS = 3
};
enum archway_io_output_mode { ARCHWAY_EXCLUSIVE = 0, ARCHWAY_OVERWRITE = 1 };
_Static_assert(sizeof(uintptr_t) == 8, "Unsupported pointer ABI");
_Static_assert(sizeof(archway_io_result) == 16, "Unsupported result ABI");
_Static_assert(offsetof(archway_io_result, native_error) == 8, "Unsupported error ABI");
_Static_assert(offsetof(archway_io_result, status) == 12, "Unsupported status ABI");

// All paths are NUL-terminated UTF-8. Children are single normalized names.
// Calls retain no pointers. Buffers belong to caller; use this allocator pair.
ARCHWAY_API int32_t archway_io_version(void);
ARCHWAY_API void *archway_io_alloc(uint64_t size);
ARCHWAY_API void archway_io_free(void *pointer);
ARCHWAY_API archway_io_result archway_io_open_root(const char *path);
ARCHWAY_API archway_io_result archway_io_open_child_directory(uint64_t parent, const char *name);
// Overwrite validates the opened ordinary file before same-handle truncation.
ARCHWAY_API archway_io_result archway_io_open_output(uint64_t parent, const char *name, uint32_t mode);
// Existing entries (including dangling links) return success/value=1.
ARCHWAY_API archway_io_result archway_io_observe_child(uint64_t parent, const char *name);
ARCHWAY_API archway_io_result archway_io_write(uint64_t handle, const void *bytes, uint64_t length);
ARCHWAY_API archway_io_result archway_io_flush(uint64_t handle);
ARCHWAY_API archway_io_result archway_io_close(uint64_t handle);
// Complete counted evidence only. Exact capacity returns BUFFER_TOO_SMALL;
// no bytes may be used from a failed call, including at the caller's ceiling.
ARCHWAY_API archway_io_result archway_io_read_alias(const char *path, void *bytes, uint64_t capacity);
#endif
