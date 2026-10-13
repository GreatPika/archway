#!/bin/sh
# Maintainer-only assembly. Package channels reuse the prepared native layout.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
  npm|npm-private-linux|pub|pub-private-linux)
    exec python3 "$root/tool/package_delivery.py" "$@"
    ;;
esac
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)
    getconf GNU_LIBC_VERSION >/dev/null 2>&1 || {
      echo 'Assembly currently requires glibc.' >&2
      exit 1
    }
    target=linux-x64
    builder=build_native.sh
    label='Linux x64'
    ;;
  Darwin/arm64)
    target=macos-arm64
    builder=build_native_macos.sh
    label='macOS arm64'
    ;;
  *)
    echo 'Assembly currently supports Linux x64 and macOS arm64 only.' >&2
    exit 1
    ;;
esac
out=${1:-"$root/build/install"}
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
[ ! -e "$out" ] && [ ! -L "$out" ] || { echo "Assembly output already exists: $out" >&2; exit 1; }
for asset in typescript/lib/typescript.js yaml/dist/index.js; do
  [ -f "$root/assets/typescript/vendor/$asset" ] || {
    echo 'Prepare pinned assets with tool/prepare_typescript.sh first.' >&2
    exit 1
  }
done
mkdir -p "$(dirname -- "$out")"
stage=$(mktemp -d "$(dirname -- "$out")/.archway-assembly-XXXXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/bin/$target" "$stage/assets/typescript"
sh "$root/tool/$builder" "$stage/native/$target"
cp "$root"/assets/typescript/*.cjs "$root"/assets/typescript/*.json \
  "$root"/assets/typescript/*.md "$stage/assets/typescript/"
cp -R "$root/assets/typescript/licenses" "$stage/assets/typescript/licenses"
cp -R "$root/assets/typescript/vendor" "$stage/assets/typescript/vendor"
cd "$root"
dart --suppress-analytics compile exe -Darchway.native=true bin/archway.dart \
  -o "$stage/bin/$target/archway"
mv "$stage" "$out"
trap - EXIT HUP INT TERM
printf 'Assembled %s installation: %s\n' "$label" "$out"
