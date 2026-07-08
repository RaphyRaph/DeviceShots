#!/bin/zsh
# Builds "Device Shots.app" next to this script.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="Device Shots.app"
# Assemble and sign in a temp dir: this folder may be iCloud-synced, and the
# sync daemon races xattrs (FinderInfo) onto fresh files, which codesign rejects.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"
cp .build/release/DeviceShots "$STAGE/$APP/Contents/MacOS/"
cp Assets/AppIcon.icns "$STAGE/$APP/Contents/Resources/"

cat > "$STAGE/$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>DeviceShots</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.raphael.deviceshots</string>
	<key>CFBundleName</key>
	<string>Device Shots</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

xattr -cr "$STAGE/$APP"
# Sign with a stable identity so TCC permissions (Accessibility) survive
# rebuilds; ad-hoc signatures change every build and reset the grants.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$STAGE/$APP"

rm -rf "$APP"
ditto "$STAGE/$APP" "$APP"
echo "Built $PWD/$APP (signed as ${IDENTITY:-ad-hoc})"

# ./build.sh install — also copy to /Applications and relaunch it from there
if [[ "$1" == "install" ]]; then
    pkill -x DeviceShots || true
    ditto "$STAGE/$APP" "/Applications/$APP"
    open "/Applications/$APP"
    echo "Installed and launched /Applications/$APP"
fi
