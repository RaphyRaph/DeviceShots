#!/bin/zsh
# Builds Screenshotter.app next to this script.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=Screenshotter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Screenshotter "$APP/Contents/MacOS/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Screenshotter</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.raphael.screenshotter</string>
	<key>CFBundleName</key>
	<string>Screenshotter</string>
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

xattr -cr "$APP"
# Sign with a stable identity so TCC permissions (Accessibility) survive
# rebuilds; ad-hoc signatures change every build and reset the grants.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $PWD/$APP (signed as ${IDENTITY:-ad-hoc})"

# ./build.sh install — also copy to /Applications and relaunch it from there
if [[ "$1" == "install" ]]; then
    pkill -x Screenshotter || true
    ditto "$APP" "/Applications/$APP"
    open "/Applications/$APP"
    echo "Installed and launched /Applications/$APP"
fi
