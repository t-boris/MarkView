#!/bin/bash
set -e

echo "Building MarkView (Release)..."
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Release archive -archivePath build/MarkView.xcarchive -quiet

echo "Installing to /Applications..."
rm -rf /Applications/MarkView.app
cp -R build/MarkView.xcarchive/Products/Applications/MarkView.app /Applications/

echo "Done! MarkView installed to /Applications/MarkView.app"
open /Applications/MarkView.app
