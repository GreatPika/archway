#!/bin/sh
# Build our owned bridge only; never compile or execute inspected project code.
set -eu
[ "$(uname -s)/$(uname -m)" = Linux/x86_64 ] || {
  echo 'The native I/O bridge currently supports Linux x64 only.' >&2
  exit 1
}
getconf GNU_LIBC_VERSION >/dev/null 2>&1 || {
  echo 'The native I/O bridge currently requires glibc.' >&2
  exit 1
}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/native/linux-x64"}
mkdir -p "$out"
cc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -fvisibility=hidden \
  -shared -Wl,-z,relro,-z,now -Wl,-soname,libarchway_io.so \
  "$root/native/linux_io.c" -o "$out/libarchway_io.so"
