#!/bin/bash
set -e

# Check the build tools before closing the running app or changing its installation.
if ! XCODE_VERSION=$(xcodebuild -version 2>&1); then
    printf '%s\n' "$XCODE_VERSION" >&2
    cat >&2 <<'EOF'

MarkView requires a working full Xcode installation to build from source.
The standalone Command Line Tools package is not sufficient.

1. Install Xcode from the Mac App Store.
2. Open Xcode once and complete its first-launch setup.
3. Select Xcode and verify the build tools (adjust the path if needed):
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
4. Run ./install.sh again.

If DEVELOPER_DIR is set, it overrides xcode-select; update or unset it first.
For a prebuilt app, download the DMG from:
https://github.com/t-boris/MarkView/releases
EOF
    exit 1
fi

# Gracefully quit, then force-kill if needed
osascript -e 'tell application "MarkView" to quit' 2>/dev/null || true
sleep 1
pkill -9 MarkView 2>/dev/null || true
sleep 1

echo "Building MarkView (Release)..."
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Release archive -archivePath build/MarkView.xcarchive -quiet

echo "Installing to /Applications..."
rm -rf /Applications/MarkView.app
cp -R build/MarkView.xcarchive/Products/Applications/MarkView.app /Applications/

# Sync API keys from sandbox container to global defaults (sandbox OFF reads global)
CONTAINER_PLIST="$HOME/Library/Containers/com.markview.MarkView/Data/Library/Preferences/com.markview.MarkView.plist"
if [ -f "$CONTAINER_PLIST" ]; then
    for KEY in "com.markview.dde.openai.apikey"; do
        VAL=$(defaults read "$CONTAINER_PLIST" "$KEY" 2>/dev/null) && \
            defaults write com.markview.MarkView "$KEY" "$VAL" 2>/dev/null || true
    done
fi

echo "Done! MarkView installed to /Applications/MarkView.app"
open /Applications/MarkView.app
