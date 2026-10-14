#!/usr/bin/env bash
# Record prerequisites before interpreting any test failure as semantic red.
set -euo pipefail
sw_vers
uname -sm
printf 'Runner image: %s %s\n' "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
printf 'Source: %s\n' "$(git rev-parse HEAD)"
[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]
[[ "$(sw_vers -productVersion)" == 15.* ]]
xcrun --show-sdk-version
xcrun clang --version
# Node is not invoked by these source-seam policy/init commands.
if command -v node >/dev/null; then node --version; fi
mkdir -p "$RUNNER_TEMP/archway-apfs"
probe_tmp=$(cd "$RUNNER_TEMP/archway-apfs" && pwd -P)
# diskutil accepts a device or mount point, not an arbitrary subdirectory.
device=$(df -P "$probe_tmp" | awk 'NR == 2 { print $1 }')
[[ "$device" == /dev/* && "$device" != *$'\n'* ]] || {
  echo 'Cannot identify the test directory filesystem device.' >&2
  exit 1
}
printf 'Test directory filesystem device: %s\n' "$device"
diskutil info "$device"
diskutil info -plist "$device" > "$RUNNER_TEMP/archway-volume.plist"
filesystem=$(plutil -extract FilesystemType raw -o - "$RUNNER_TEMP/archway-volume.plist")
if [[ "$(printf '%s' "$filesystem" | tr '[:upper:]' '[:lower:]')" != apfs ]]; then
  echo 'APFS required; this is a prerequisite failure, not target red' >&2
  exit 1
fi
case_probe=$(mktemp -d "$probe_tmp/case-probe-XXXXXX")
trap 'rm -rf "$case_probe"' EXIT
printf probe > "$case_probe/case-check"
if [[ -e "$case_probe/CASE-CHECK" ]]; then
  echo 'APFS case-sensitive: False'
else
  echo 'APFS case-sensitive: True'
fi
printf 'Canonical test TMPDIR: %s\n' "$probe_tmp"
rm -rf "$case_probe"
trap - EXIT
echo "TMPDIR=$probe_tmp/" >> "$GITHUB_ENV"
