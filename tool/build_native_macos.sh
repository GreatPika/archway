#!/bin/sh
# Maintainer-only build of Archway's bridge using the installed Apple toolchain.
set -eu
[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || {
  echo 'The macOS native I/O bridge requires a native macOS arm64 builder.' >&2
  exit 1
}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/native/macos-arm64"}
mkdir -p "$out"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 \
  -std=c11 -O2 -Wall -Wextra -Werror -fvisibility=hidden -dynamiclib \
  -Wl,-install_name,@rpath/libarchway_io.dylib \
  "$root/native/macos_io.c" -o "$out/libarchway_io.dylib"
