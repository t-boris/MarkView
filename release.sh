#!/bin/bash
# Build a signed MarkView release and its installer (DMG).
#
#   ./release.sh              build/MarkView-<version>.dmg, signed with Developer ID
#   ./release.sh --install    ...and install it into /Applications from the DMG
#
# Set NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile to notarize and
# staple the DMG as well (without it, first launch needs "Open Anyway" in
# System Settings → Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"?MARKETING_VERSION"?: *"?([0-9.]+)"?.*/\1/')
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')}
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity found (set SIGN_IDENTITY)"; exit 1; }

BUILD=build/release
APP=$BUILD/MarkView.app
DMG=build/MarkView-$VERSION.dmg
rm -rf "$BUILD" "$DMG"
mkdir -p "$BUILD"

echo "▸ Building MarkView $VERSION (Release)…"
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Release \
    -derivedDataPath build/ReleaseDerivedData CODE_SIGNING_ALLOWED=NO -quiet build
cp -R build/ReleaseDerivedData/Build/Products/Release/MarkView.app "$APP"

echo "▸ Signing with $IDENTITY (hardened runtime)…"
codesign --force --options runtime --timestamp \
    --entitlements MarkView/MarkView.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Creating the installer…"
STAGE=$BUILD/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MarkView $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▸ Notarizing…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG"
echo "✓ $DMG"

if [ "${1:-}" = "--install" ]; then
    echo "▸ Installing from the DMG…"
    osascript -e 'tell application "MarkView" to quit' 2>/dev/null || true
    sleep 1
    pkill -x MarkView 2>/dev/null || true
    MOUNT=$(mktemp -d)
    hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
    rm -rf /Applications/MarkView.app
    ditto "$MOUNT/MarkView.app" /Applications/MarkView.app
    hdiutil detach "$MOUNT" -quiet
    echo "✓ Installed /Applications/MarkView.app ($VERSION)"
    open /Applications/MarkView.app
fi
