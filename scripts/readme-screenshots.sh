#!/bin/zsh
# Captures the README screenshots from the real app (debug build, demo data)
# in light and dark: docs/images/<shot>-<appearance>.png
#
# The debug binary is wrapped in a throwaway app bundle and launched with
# `open` so its windows can activate (a bare binary launched from a script
# usually can't come to the front, so windows would look inactive).
set -e
cd "$(dirname "$0")/.."
OUT=docs/images
mkdir -p "$OUT"
swift build >/dev/null

APP=.build/readme/DeviceShotsDemo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/DeviceShots "$APP/Contents/MacOS/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>DeviceShots</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.raphael.deviceshots.readme-demo</string>
	<key>CFBundleName</key><string>Device Shots</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null

# name | window match (title substring, or --menu) | launch option
shots=(
    "menu|--menu|DEVICESHOTS_OPEN_MENU=1"
    "settings-shortcuts|Shortcuts|DEVICESHOTS_OPEN_SETTINGS=shortcuts"
    "settings-capture|Capture|DEVICESHOTS_OPEN_SETTINGS=capture"
    "setup-android|Set up|DEVICESHOTS_SHOW_SETUP=android"
)

for appearance in light dark; do
    for shot in $shots; do
        name=${shot%%|*}; rest=${shot#*|}; match=${rest%%|*}; option=${rest#*|}
        open -n -W "$APP" --env DEVICESHOTS_DEMO=1 --env DEVICESHOTS_APPEARANCE=$appearance --env "$option" &
        opener=$!
        sleep 4
        pid=$(pgrep -n -f "$APP/Contents/MacOS/DeviceShots")
        if ! wid=$(swift scripts/window-id.swift $pid "$match"); then
            echo "No window for $name ($appearance)"; kill $pid; exit 1
        fi
        screencapture -l "$wid" "$OUT/$name-$appearance.png"
        kill $pid
        wait $opener 2>/dev/null || true
    done
done
ls "$OUT"
