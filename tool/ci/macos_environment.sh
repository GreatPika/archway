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
python3 - "$RUNNER_TEMP/archway-volume.plist" "$probe_tmp" <<'PY'
import pathlib, plistlib, sys, tempfile
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
if info.get("FilesystemType", "").lower() != "apfs":
    raise SystemExit("APFS required; this is a prerequisite failure, not target red")
with tempfile.TemporaryDirectory(prefix="case-probe-", dir=sys.argv[2]) as root:
    lower = pathlib.Path(root, "case-check")
    lower.write_text("probe", encoding="ascii")
    print("APFS case-sensitive:", not pathlib.Path(root, "CASE-CHECK").exists())
print("Canonical test TMPDIR:", sys.argv[2])
PY
echo "TMPDIR=$probe_tmp/" >> "$GITHUB_ENV"
