#!/bin/zsh
# Builds, signs (Developer ID + hardened runtime), notarizes, and staples a
# distributable Screenshotter.zip.
#
# One-time setup:
#   1. Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates
#      → "+" → "Developer ID Application"
#   2. Create an app-specific password at https://account.apple.com
#   3. xcrun notarytool store-credentials screenshotter-notary \
#        --apple-id <your-apple-id> --team-id GPF64GK459
set -e
cd "$(dirname "$0")"

VERSION="v$(awk '/CFBundleShortVersionString/{getline; gsub(/[^0-9.]/,""); print; exit}' build.sh)"
echo "Releasing version ${VERSION}"

./build.sh

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: no 'Developer ID Application' certificate found."
    echo "Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application"
    exit 1
fi

echo "Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" Screenshotter.app

ZIP="Screenshotter-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Screenshotter.app "$ZIP"

echo "Submitting to Apple notary service (takes a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile screenshotter-notary --wait

xcrun stapler staple Screenshotter.app

# Re-zip with the stapled ticket so the download validates offline too.
rm -f "$ZIP"
ditto -c -k --keepParent Screenshotter.app "$ZIP"

echo ""
echo "Done: $PWD/$ZIP"
echo "Publish with: gh release create ${VERSION} ${ZIP} --title \"Screenshotter ${VERSION}\""
