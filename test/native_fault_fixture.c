// Test-only syscall substitution around the real host POSIX bridge. Product sources
// expose no switch. Outcomes are observed through the assembled CLI executable.
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static ssize_t fixture_write(int fd, const void *bytes, size_t length);
static int fixture_fsync(int fd);
static ssize_t fixture_readlink(const char *path, char *bytes, size_t capacity);
static int fixture_close(int fd);
static int fixture_fstat(int fd, struct stat *st);
static int fixture_fstatat(int fd, const char *name, struct stat *st, int flags);
#define readlink fixture_readlink
#define write fixture_write
#define fsync fixture_fsync
#define close fixture_close
#define fstat fixture_fstat
#define fstatat fixture_fstatat
#ifdef __APPLE__
#include "macos_io.c"
#else
#include "linux_io.c"
#endif
#undef readlink
#undef write
#undef fsync
#undef close
#undef fstat
#undef fstatat

static int is_fault(const char *name) {
  const char *fault = getenv("ARCHWAY_TEST_FAULT");
  return fault && strcmp(fault, name) == 0;
}
static ssize_t fixture_write(int fd, const void *bytes, size_t length) {
  static int interrupted = 0;
  if (is_fault("interrupted") && !interrupted++) { errno = EINTR; return -1; }
  if (is_fault("zero")) return 0;
  if (is_fault("observe")) { errno = EIO; return -1; }
  if (is_fault("partial") && length > 1) length /= 2;
  return write(fd, bytes, length);
}
static int fixture_fsync(int fd) {
  if (is_fault("flush")) { errno = EIO; return -1; }
  return fsync(fd);
}
static int fixture_close(int fd) {
  struct stat st;
  int regular = fstat(fd, &st) == 0 && S_ISREG(st.st_mode);
  // Log after the actual close; logging can itself reuse the descriptor. A
  // caller that retries consumed ownership will thus visibly close twice.
  int result = close(fd);
  int saved = errno;
  const char *path = getenv("ARCHWAY_TEST_CLOSE_LOG");
  FILE *log = path ? fopen(path, "a") : NULL;
  if (log) { fprintf(log, "%s\n", regular ? "file" : "directory"); fclose(log); }
  if (regular && is_fault("close")) { errno = EIO; return -1; }
  errno = saved;
  return result;
}
static int fixture_fstat(int fd, struct stat *st) {
  if (is_fault("validate")) { errno = EIO; return -1; }
  return fstat(fd, st);
}
static int fixture_fstatat(int fd, const char *name, struct stat *st, int flags) {
  if (is_fault("observe")) { errno = EACCES; return -1; }
  return fstatat(fd, name, st, flags);
}

static ssize_t fixture_readlink(const char *path, char *bytes, size_t capacity) {
  if (is_fault("alias_full")) return (ssize_t)capacity;
  return readlink(path, bytes, capacity);
}
