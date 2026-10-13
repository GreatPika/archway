#!/usr/bin/env bash
# Maintainer-only preparation. Never called by installation or CLI execution.
set -euo pipefail
assets="$(cd "$(dirname "$0")/../assets/typescript" && pwd)"
stage="$(mktemp -d "$assets/.prepare-XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp "$assets/package.json" "$assets/package-lock.json" "$stage/"
# npm verifies the lockfile's tarball integrity; lifecycle scripts stay disabled.
npm ci --prefix "$stage" --ignore-scripts --no-audit --no-fund
mkdir "$stage/vendor"
for package in typescript yaml; do
  cp -R "$stage/node_modules/$package" "$stage/vendor/$package"
done
# Preserve complete, unmodified npm package trees, including libraries/licenses.
# Replace only generated output after preparation succeeds.
rm -rf "$assets/vendor"
mv "$stage/vendor" "$assets/vendor"
