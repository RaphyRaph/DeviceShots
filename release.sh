#!/bin/zsh
# Builds, signs (Developer ID + hardened runtime), notarizes, and staples a
# distributable DeviceShots zip.
#
# One-time setup:
#   1. Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates
#      → "+" → "Developer ID Application"
#   2. Create an app-specific password at https://account.apple.com
#   3. xcrun notarytool store-credentials deviceshots-notary \
#        --apple-id <your-apple-id> --team-id GPF64GK459
set -e
cd "$(dirname "$0")"

VERSION="v$(awk '/CFBundleShortVersionString/{getline; gsub(/[^0-9.]/,""); print; exit}' build.sh)"
echo "Releasing version ${VERSION}"

./build.sh

APP="Device Shots.app"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: no 'Developer ID Application' certificate found."
    echo "Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
    exit 1
fi

# Work in a temp dir: this folder may be iCloud-synced and the sync daemon
# races xattrs onto files, which breaks codesign/notarization.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP"
xattr -cr "$STAGE/$APP"

echo "Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE/$APP"

ZIP="DeviceShots-${VERSION}.zip"
ditto -c -k --keepParent "$STAGE/$APP" "$STAGE/$ZIP"

echo "Submitting to Apple notary service (takes a few minutes)…"
xcrun notarytool submit "$STAGE/$ZIP" --keychain-profile deviceshots-notary --wait

xcrun stapler staple "$STAGE/$APP"

# Re-zip with the stapled ticket so the download validates offline too.
rm -f "$STAGE/$ZIP"
ditto -c -k --keepParent "$STAGE/$APP" "$STAGE/$ZIP"
mv "$STAGE/$ZIP" "$ZIP"

echo ""
echo "Done: $PWD/$ZIP"
echo "Publish with: gh release create ${VERSION} ${ZIP} --title \"Device Shots ${VERSION}\""
