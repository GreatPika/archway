#!/usr/bin/env bash
# Ephemeral CI bootstrap only; the Dart preparation owner records full evidence.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Expected bootstrap target and fresh output directory' >&2
  exit 1
fi
target=$1
case "$target" in
  linux-x64) pin=549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7 ;;
  macos-arm64) pin=c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc ;;
  windows-x64) pin=30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e ;;
  *) echo 'Unsupported bootstrap SDK target' >&2; exit 1 ;;
esac
root_native="$(node -p 'require("node:path").resolve(process.argv[1])' "$2")"
root=$root_native
if [[ "$target" == windows-x64 ]]; then root="$(cygpath -u "$root_native")"; fi
test ! -e "$root"
mkdir "$root"
curl --fail --show-error --silent --location --retry 2 --max-time 180 \
  --max-filesize 536870912 \
  "https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/dartsdk-$target-release.zip" \
  -o "$root/sdk.zip"
actual="$(node -e 'const fs=require("node:fs"),crypto=require("node:crypto");console.log(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$root/sdk.zip")"
if [[ "$actual" != "$pin" ]]; then
  echo 'Official bootstrap SDK checksum differs' >&2
  exit 1
fi
if [[ "$target" == windows-x64 ]]; then
  system_root="$(cygpath -u "${SYSTEMROOT:-${SystemRoot:?Missing Windows system root}}")"
  "$system_root/System32/tar.exe" -xf "$root/sdk.zip" -C "$root"
  dart="$root/dart-sdk/bin/dart.exe"
else
  /usr/bin/unzip -q "$root/sdk.zip" -d "$root"
  dart="$root/dart-sdk/bin/dart"
fi
"$dart" --version
node - "$root_native" "$target" <<'NODE'
const fs = require('node:fs'), path = require('node:path');
const root = process.argv[2], windows = process.argv[3] === 'windows-x64';
const bin = path.join(root, 'dart-sdk', 'bin');
fs.appendFileSync(process.env.GITHUB_PATH, `${bin}\n`);
fs.appendFileSync(process.env.GITHUB_ENV,
  `PUB_BOOTSTRAP_DART=${path.join(bin, windows ? 'dart.exe' : 'dart')}\n` +
  `PUB_BOOTSTRAP_ARCHIVE=${path.join(root, 'sdk.zip')}\n`);
NODE
