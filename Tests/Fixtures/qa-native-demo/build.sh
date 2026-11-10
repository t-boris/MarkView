#!/bin/bash
# Builds the fixture application for the native QA player's checks into the folder given as the argument and prints the path of the
# bundle. Bundle identifier com.markview.qa-native-demo; the bundle is signed ad hoc so that it starts on Apple Silicon.
#   Tests/Fixtures/qa-native-demo/build.sh <output folder>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:?usage: build.sh <output folder>}"
app="$out/QANativeDemo.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$app/Contents/MacOS/QANativeDemo" "$here/main.swift"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.markview.qa-native-demo</string>
    <key>CFBundleName</key><string>QA Native Demo</string>
    <key>CFBundleExecutable</key><string>QANativeDemo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
echo "$app"
