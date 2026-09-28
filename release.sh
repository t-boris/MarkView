#!/bin/bash
# Build a signed MarkView release and its installer (DMG).
#
#   ./release.sh              build/MarkView-<version>.dmg, signed with Developer ID
#   ./release.sh --install    ...and install it into /Applications from the DMG
#   ./release.sh --publish    ...and publish it as GitHub release v<version>, marked Latest
#                             (only from a clean checkout of origin/main; flags can be combined)
#
# Set NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile to notarize and
# staple the DMG as well (without it, first launch needs "Open Anyway" in
# System Settings → Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --publish) PUBLISH=1 ;;
        *) echo "Unknown option: $arg (use --install and/or --publish)"; exit 1 ;;
    esac
done

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"?MARKETING_VERSION"?: *"?([0-9.]+)"?.*/\1/')
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')}
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity found (set SIGN_IDENTITY)"; exit 1; }

# A published installer must be exactly the merged main commit: check before spending a build.
if [ "$PUBLISH" = 1 ]; then
    command -v gh >/dev/null || { echo "--publish needs the GitHub CLI (gh)"; exit 1; }
    git fetch -q origin main
    [ -z "$(git status --porcelain)" ] || { echo "--publish needs a clean checkout (commit or use a clean worktree)"; exit 1; }
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "--publish needs HEAD = origin/main ($(git rev-parse --short origin/main))"; exit 1; }
    if gh release view "v$VERSION" >/dev/null 2>&1; then
        echo "Release v$VERSION already exists; bump the version first"; exit 1
    fi
fi

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

if [ "$PUBLISH" = 1 ]; then
    echo "▸ Publishing release v$VERSION…"
    gh release create "v$VERSION" "$DMG" --target "$(git rev-parse HEAD)" --latest \
        --title "MarkView $VERSION" \
        --notes "Signed installer (Developer ID) built from \`main\` at $(git rev-parse --short HEAD).

1. Open \`MarkView-$VERSION.dmg\` and drag MarkView to Applications.
2. The DMG is not notarized: on first launch use System Settings → Privacy & Security → Open Anyway."
    echo "✓ $(gh release view "v$VERSION" --json url -q .url)"
fi
if [ "$INSTALL" = 1 ]; then
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
