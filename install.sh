#!/bin/bash
set -e

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
    for KEY in "com.markview.dde.apikey" "com.markview.dde.openai.apikey"; do
        VAL=$(defaults read "$CONTAINER_PLIST" "$KEY" 2>/dev/null) && \
            defaults write com.markview.MarkView "$KEY" "$VAL" 2>/dev/null || true
    done
fi

echo "Done! MarkView installed to /Applications/MarkView.app"
open /Applications/MarkView.app
