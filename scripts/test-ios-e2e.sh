#!/bin/zsh
# Builds the app, verifies the CoreDevice JSON parser, then exercises the live
# iPhone screenshot pipeline. The captured PNG stays in /private/tmp and is
# deleted before the script exits.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for XCODE_APP in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [[ -x "$XCODE_APP/Contents/Developer/usr/bin/devicectl" ]]; then
            export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
            break
        fi
    done
fi

if [[ ! -x "${DEVELOPER_DIR:-}/usr/bin/devicectl" ]]; then
    print -u2 "FAIL: Full Xcode with devicectl is required."
    exit 1
fi

# This repository is iCloud-synced. Keep XCTest's signed bundle outside it so
# Finder metadata cannot be copied onto the bundle between build and codesign.
TEST_DERIVED_DATA=/private/tmp/deviceshots-test-derived
mkdir -p "$TEST_DERIVED_DATA"
xattr -cr "$TEST_DERIVED_DATA" 2>/dev/null || true
swift test --scratch-path "$TEST_DERIVED_DATA"

devices_json=$(mktemp /private/tmp/deviceshots-e2e-devices.XXXXXX.json)
screenshot_png=$(mktemp /private/tmp/deviceshots-e2e-screenshot.XXXXXX.png)
trap 'rm -f "$devices_json" "$screenshot_png"' EXIT

/usr/bin/xcrun devicectl list devices --quiet --json-output "$devices_json" --timeout 20
# CoreDevice may leave tunnelState "disconnected" on a plugged-in phone while
# still allowing screenshot capture over the wired transport.
device_id=$(jq -r '
    .result.devices[]
    | select(.hardwareProperties.reality == "physical")
    | select(
        .connectionProperties.tunnelState == "connected"
        or .connectionProperties.transportType == "wired"
      )
    | .identifier
' "$devices_json" | head -n 1)

if [[ -z "$device_id" || "$device_id" == "null" ]]; then
    print -u2 "FAIL: No connected physical iPhone or iPad (wired or CoreDevice tunnel)."
    exit 1
fi

print "Capturing one temporary screenshot from $device_id…"
/usr/bin/xcrun devicectl device capture screenshot --device "$device_id" \
    --destination "$screenshot_png" --quiet --timeout 30

if [[ "$(od -An -tx1 -N4 "$screenshot_png" | tr -d '[:space:]')" != "89504e47" ]]; then
    print -u2 "FAIL: devicectl did not write a PNG."
    exit 1
fi

print "PASS: iOS discovery and screenshot capture succeeded; temporary output was validated."
