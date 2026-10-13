#!/bin/sh
# Only macOS-provided tools are used on the installing machine.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
ROOT=/usr/local/lib/archway
COMMAND=/usr/local/bin/archway
IDENTIFIER=org.archway.cli
INVENTORY=$ROOT/.archway-owned.sha256
TARGET=$ROOT/bin/macos-arm64/archway
fail() { echo "Archway installer: $*" >&2; exit 1; }
ancestors() {
    ancestor=$1
    while [ "$ancestor" != / ]; do
        [ ! -L "$ancestor" ] || fail "Aliased installation path: $ancestor"
        if [ -e "$ancestor" ]; then
            [ -d "$ancestor" ] || fail "Non-directory installation parent: $ancestor"
        fi
        ancestor=$(dirname "$ancestor")
    done
}
command_check() {
    if [ -e "$COMMAND" ] || [ -L "$COMMAND" ]; then
        [ -f "$INVENTORY" ] && [ -L "$COMMAND" ] &&
            [ "$(readlink "$COMMAND")" = "$TARGET" ] ||
            fail "Refusing conflicting command: $COMMAND"
    fi
}
preinstall() {
    [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || fail "Requires native macOS arm64"
    [ "${3:-/}" = / ] || fail "Only the running system volume is supported"
    ancestors "$ROOT"
    ancestors "$(dirname "$COMMAND")"
    if [ -e "$ROOT" ] || [ -L "$ROOT" ]; then
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] && [ -f "$INVENTORY" ] &&
            [ ! -L "$INVENTORY" ] && /usr/sbin/pkgutil --pkg-info "$IDENTIFIER" >/dev/null 2>&1 ||
            fail "Refusing foreign installation root: $ROOT"
    fi
    command_check
    scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    validate_inventory "$scripts/owned.sha256"
    if [ -f "$INVENTORY" ]; then
        validate_inventory "$INVENTORY"
        while read -r hash mode relative; do
            ancestors "$(dirname "$ROOT/$relative")"
            unchanged "$hash" "$mode" "$relative" || fail "Owned file changed or missing: $relative"
        done < "$INVENTORY"
    fi
    while read -r hash mode relative; do
        ancestors "$(dirname "$ROOT/$relative")"
        if [ -e "$ROOT/$relative" ] || [ -L "$ROOT/$relative" ]; then
            [ -f "$INVENTORY" ] && [ -n "$(owned_hash "$INVENTORY" "$relative")" ] ||
                fail "New payload would replace foreign file: $relative"
        fi
    done < "$scripts/owned.sha256"
}
validate_inventory() {
    [ -f "$1" ] && [ ! -L "$1" ] || fail "Missing owned-file inventory"
    LC_ALL=C awk '
        NF != 3 || ($2 != "644" && $2 != "755") || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
        $3 !~ /^[A-Za-z0-9_.\/-]+$/ || $3 ~ /(^|\/)\.\.?($|\/)/ ||
        $3 ~ /^\/|\/\/|\/$/ || seen[$3]++ {exit 1}
        END {if (NR == 0) exit 1}
    ' "$1" || fail "Invalid owned-file inventory"
}
owned_hash() { awk -v name="$2" '$3 == name {print $1}' "$1"; }
unchanged() {
    [ -f "$ROOT/$3" ] && [ ! -L "$ROOT/$3" ] || return 1
    actual_mode=$(stat -f '%Op' "$ROOT/$3") || return 1
    [ "$((0$actual_mode & 07777))" -eq "$((0$2))" ] &&
        [ "$(shasum -a 256 "$ROOT/$3" | cut -d ' ' -f 1)" = "$1" ]
}
remove_owned() {
    validate_inventory "$1"
    while read -r hash mode relative; do
        ancestors "$(dirname "$ROOT/$relative")"
        if [ -n "${2:-}" ] && [ -n "$(owned_hash "$2" "$relative")" ]; then continue; fi
        if unchanged "$hash" "$mode" "$relative"; then
            rm "$ROOT/$relative"
            directory=$(dirname "$ROOT/$relative")
            while [ "$directory" != "$ROOT" ]; do
                rmdir "$directory" 2>/dev/null || break
                directory=$(dirname "$directory")
            done
        fi
    done < "$1"
}
postinstall() {
    [ "${3:-/}" = / ] || fail "Only the running system volume is supported"
    ancestors "$ROOT"
    ancestors "$(dirname "$COMMAND")"
    command_check
    scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    validate_inventory "$scripts/owned.sha256"
    while read -r hash mode relative; do
        ancestors "$(dirname "$ROOT/$relative")"
        unchanged "$hash" "$mode" "$relative" || fail "Installed payload mismatch: $relative"
    done < "$scripts/owned.sha256"
    if [ -f "$INVENTORY" ]; then remove_owned "$INVENTORY" "$scripts/owned.sha256"; fi
    cp "$scripts/owned.sha256" "$INVENTORY"
    chmod 644 "$INVENTORY"
    mkdir -p "$(dirname "$COMMAND")"
    command_check
    if [ ! -L "$COMMAND" ]; then ln -s "$TARGET" "$COMMAND"; fi
}
uninstall() {
    ancestors "$ROOT"
    ancestors "$(dirname "$COMMAND")"
    /usr/sbin/pkgutil --pkg-info "$IDENTIFIER" >/dev/null 2>&1 || fail "No Archway receipt"
    validate_inventory "$INVENTORY"
    # Check every parent before deleting anything; never traverse user aliases.
    while read -r hash mode relative; do ancestors "$(dirname "$ROOT/$relative")"; done < "$INVENTORY"
    if [ -L "$COMMAND" ] && [ "$(readlink "$COMMAND")" = "$TARGET" ]; then rm "$COMMAND"; fi
    remove_owned "$INVENTORY"
    /usr/sbin/pkgutil --forget "$IDENTIFIER" >/dev/null || fail "Could not forget receipt"
    rm "$INVENTORY"
    rmdir "$ROOT" 2>/dev/null || echo "Preserved modified or foreign files in $ROOT"
}
