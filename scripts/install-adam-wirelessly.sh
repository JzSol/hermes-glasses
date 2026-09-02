#!/bin/sh

set -eu

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

fail() {
    printf 'Adam wireless install blocked: %s\n' "$1" >&2
    exit 1
}

[ "$(git branch --show-current)" = "main" ] || \
    fail "switch to main before installing Adam"
[ -z "$(git status --porcelain --untracked-files=normal)" ] || \
    fail "commit every worktree change before installing"

upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
[ "$upstream" = "origin/main" ] || fail "main must track origin/main"
local_head=$(git rev-parse HEAD)
tracked_head=$(git rev-parse origin/main)
[ "$local_head" = "$tracked_head" ] || \
    fail "local main does not match the fetched origin/main"
remote_head=$(git ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
[ -n "$remote_head" ] || fail "could not read origin/main"
[ "$local_head" = "$remote_head" ] || \
    fail "origin/main changed; integrate and verify it before installing"

[ -f Config/AdamVoice.local.xcconfig ] || \
    fail "create ignored Config/AdamVoice.local.xcconfig first"

for command in xcodebuild xcrun plutil python3; do
    command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done

temporary_directory=$(mktemp -d /tmp/adam-wireless.XXXXXX)
cleanup() {
    find "$temporary_directory" -type f -delete 2>/dev/null || true
    rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

devices_json="$temporary_directory/devices.json"
selection_json="$temporary_directory/selection.json"
preinstall_devices_json="$temporary_directory/preinstall-devices.json"
preinstall_selection_json="$temporary_directory/preinstall-selection.json"
postinstall_devices_json="$temporary_directory/postinstall-devices.json"
postinstall_selection_json="$temporary_directory/postinstall-selection.json"
apps_json="$temporary_directory/apps.json"

xcrun devicectl list devices \
    --json-output "$devices_json" \
    --quiet \
    --timeout 15 || fail "could not query CoreDevice"

requested_identifier=${1:-}
if [ -n "$requested_identifier" ]; then
    /usr/bin/python3 scripts/adam-wireless-device.py select \
        "$devices_json" "$requested_identifier" > "$selection_json" || exit $?
else
    /usr/bin/python3 scripts/adam-wireless-device.py select \
        "$devices_json" > "$selection_json" || exit $?
fi

device_identifier=$(/usr/bin/plutil -extract identifier raw -o - "$selection_json")
device_udid=$(/usr/bin/plutil -extract udid raw -o - "$selection_json")
device_name=$(/usr/bin/plutil -extract name raw -o - "$selection_json")
transport=$(/usr/bin/plutil -extract transport raw -o - "$selection_json")

confirm_wireless_transport() {
    phase=$1
    devices_path=$2
    selection_path=$3
    xcrun devicectl list devices \
        --json-output "$devices_path" \
        --quiet \
        --timeout 15 || fail "could not recheck CoreDevice before $phase"
    /usr/bin/python3 scripts/adam-wireless-device.py confirm \
        "$devices_path" "$device_identifier" "$device_udid" \
        > "$selection_path" || exit $?
}

derived_data="${TMPDIR:-/tmp}"
derived_data="${derived_data%/}/adamvoice-wireless-build"
app_path="$derived_data/Build/Products/Debug-iphoneos/Adam.app"

printf 'Building Adam for %s via %s...\n' "$device_name" "$transport"
xcodebuild \
    -project HermesGlasses.xcodeproj \
    -scheme AdamVoice \
    -configuration Debug \
    -destination "platform=iOS,id=${device_udid}" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    build \
    -quiet

[ -d "$app_path" ] || fail "signed Adam.app was not produced"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")

printf 'Installing Adam %s (%s) without uninstalling the current app...\n' \
    "$version" "$build"
confirm_wireless_transport "install" \
    "$preinstall_devices_json" "$preinstall_selection_json"
xcrun devicectl device install app \
    --device "$device_identifier" \
    "$app_path"
xcrun devicectl device process launch \
    --device "$device_identifier" \
    --terminate-existing \
    com.vandret.adamvoice
xcrun devicectl device info apps \
    --device "$device_identifier" \
    --bundle-id com.vandret.adamvoice \
    --json-output "$apps_json" \
    --quiet \
    --timeout 20
/usr/bin/python3 scripts/adam-wireless-device.py verify \
    "$apps_json" "$version" "$build" >/dev/null
confirm_wireless_transport "final verification" \
    "$postinstall_devices_json" "$postinstall_selection_json"

printf 'Adam %s (%s) is installed and running wirelessly on %s.\n' \
    "$version" "$build" "$device_name"
