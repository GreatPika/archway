#define _GNU_SOURCE
#include "io.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static archway_io_result ok(uint64_t value) {
  return (archway_io_result){value, 0, ARCHWAY_OK};
}
static archway_io_result failed(int error) {
  uint32_t category = ARCHWAY_OTHER;
  if (error == ENOENT) category = ARCHWAY_MISSING;
  else if (error == EEXIST) category = ARCHWAY_EXISTS;
  else if (error == EINTR) category = ARCHWAY_INTERRUPTED;
  return (archway_io_result){0, (uint32_t)error, category | (ARCHWAY_POSIX << 16)};
}
static archway_io_result invalid(void) {
  return (archway_io_result){0, 0, ARCHWAY_OTHER};
}
static archway_io_result unsupported(void) {
  return (archway_io_result){0, 0, ARCHWAY_UNSUPPORTED_ENTRY};
}
static int descriptor(uint64_t handle) {
  return handle <= INT_MAX ? (int)handle : -1;
}
static int child(const char *name) {
  return name && *name && !strchr(name, '/') && strcmp(name, ".") && strcmp(name, "..");
}
static archway_io_result opened(int fd) {
  return fd < 0 ? failed(errno) : ok((uint64_t)fd);
}

int32_t archway_io_version(void) { return 2; }
void *archway_io_alloc(uint64_t size) { return malloc((size_t)size); }
void archway_io_free(void *pointer) { free(pointer); }

archway_io_result archway_io_open_root(const char *path) {
  if (!path || *path != '/') return invalid();
  return opened(open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
}
archway_io_result archway_io_open_child_directory(uint64_t parent, const char *name) {
  if (!child(name)) return invalid();
  return opened(openat(descriptor(parent), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
}
archway_io_result archway_io_open_output(uint64_t parent, const char *name, uint32_t mode) {
  if (!child(name) || mode > ARCHWAY_OVERWRITE) return invalid();
  int flags = O_WRONLY | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC;
  if (mode == ARCHWAY_EXCLUSIVE) flags |= O_EXCL;
  int fd = openat(descriptor(parent), name, flags, 0644);
  if (fd < 0) return failed(errno);
  struct stat st;
  archway_io_result result;
  if (fstat(fd, &st) < 0) result = failed(errno);
  else if (!S_ISREG(st.st_mode)) result = unsupported();
  else if (mode == ARCHWAY_OVERWRITE && ftruncate(fd, 0) < 0) result = failed(errno);
  else return ok((uint64_t)fd);
  // Capture the primary failure before cleanup. No handle is transferred.
  (void)close(fd);
  return result;
}
archway_io_result archway_io_observe_child(uint64_t parent, const char *name) {
  if (!child(name)) return invalid();
  struct stat st;
  if (fstatat(descriptor(parent), name, &st, AT_SYMLINK_NOFOLLOW) < 0) return failed(errno);
  return ok(1);
}
archway_io_result archway_io_write(uint64_t handle, const void *bytes, uint64_t length) {
  size_t count = length > (uint64_t)SSIZE_MAX ? (size_t)SSIZE_MAX : (size_t)length;
  ssize_t result = write(descriptor(handle), bytes, count);
  return result < 0 ? failed(errno) : ok((uint64_t)result);
}
archway_io_result archway_io_flush(uint64_t handle) {
  return fsync(descriptor(handle)) < 0 ? failed(errno) : ok(0);
}
archway_io_result archway_io_close(uint64_t handle) {
  return close(descriptor(handle)) < 0 ? failed(errno) : ok(0);
}
archway_io_result archway_io_read_alias(const char *path, void *bytes, uint64_t capacity) {
  if (capacity == 0 || capacity > (uint64_t)SSIZE_MAX) return invalid();
  ssize_t result = readlink(path, bytes, (size_t)capacity);
  if (result < 0) return failed(errno);
  if ((uint64_t)result == capacity) return (archway_io_result){0, 0, ARCHWAY_BUFFER_TOO_SMALL};
  return ok((uint64_t)result);
}
