#!/bin/zsh
# Builds "Device Shots.app" next to this script.
set -e
cd "$(dirname "$0")"

# Finder launches and this shell can both inherit Command Line Tools as the
# active developer directory. Prefer an installed full Xcode when no explicit
# toolchain was requested; Device Shots needs SwiftUI plus devicectl/simctl.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    for XCODE_APP in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [[ -x "$XCODE_APP/Contents/Developer/usr/bin/devicectl" ]]; then
            export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
            break
        fi
    done
fi

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
	<string>1.2</string>
	<key>LSMinimumSystemVersion</key>
	<string>27.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

xattr -cr "$STAGE/$APP"
# Sign with the same Developer ID identity as the shipped app so TCC keeps its
# Accessibility grant across local rebuilds. Apple Development is a fallback
# for contributors without the Developer ID certificate.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$STAGE/$APP"

rm -rf "$APP"
ditto "$STAGE/$APP" "$APP"
echo "Built $PWD/$APP (signed as ${IDENTITY:-ad-hoc})"

# ./build.sh install — also copy to /Applications and relaunch it from there
if [[ "$1" == "install" ]]; then
    echo "Installing a local Developer ID build. Use ./release.sh for a notarized distributable."
    pkill -x DeviceShots || true
    # `ditto` merges with an existing bundle, preserving Finder metadata that
    # invalidates the clean signature created above. Replace this exact app
    # bundle instead of merging it.
    rm -rf "/Applications/$APP"
    ditto "$STAGE/$APP" "/Applications/$APP"
    codesign --verify --deep --strict "/Applications/$APP"
    open "/Applications/$APP"
    echo "Installed and launched /Applications/$APP"
fi
