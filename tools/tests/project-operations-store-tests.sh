#!/bin/bash
# What the shipping ProjectOperationsStore does when it needs the person's decision (AR-22): the question goes through the prompter the
# store was given (a scripted stand-in for the person), and anything but the confirming answer changes nothing: no run starts, no
# operation is adopted or accepted, nothing is written. The store, the discovery service, the operations file, the run history and the
# scanner are the shipping code over temporary projects; the terminal of a run and the assistant of discovery are stand-ins
# (ProjectOperationsStoreStubs.swift). The store asks the system's notification center for its delegate when it is made, which needs an
# application bundle: the check runs as a bundle of its own (background only, never shown) and leaves its preferences domain empty.
#   tools/tests/project-operations-store-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
bundle_id=com.markview.tests.operations-store
# `defaults delete` goes through the preferences daemon, which would otherwise write the file back after it is removed.
trap 'rm -rf "$out"; defaults delete "$bundle_id" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$bundle_id.plist"' EXIT
target="$(uname -m)-apple-macos13.0"
swiftc -parse-as-library -wmo -target "$target" -module-name MarkViewCore -emit-module -emit-module-path "$out/MarkViewCore.swiftmodule" \
    -c Packages/MarkViewCore/Sources/MarkViewCore/*.swift -o "$out/MarkViewCore.o"
app="$out/OperationsStoreTests.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>operations-store-tests</string>
<key>CFBundleName</key><string>operations-store-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
swiftc -parse-as-library -target "$target" -I "$out" -o "$app/Contents/MacOS/operations-store-tests" "$out/MarkViewCore.o" \
    MarkView/Models/ProjectOps/ProjectOperationsStore.swift MarkView/Models/ProjectOps/ProjectOperation.swift \
    MarkView/Models/ProjectOps/ProjectOperationDiscovery.swift MarkView/Models/ProjectOps/ProjectOperationDiscoveryService.swift \
    MarkView/Models/ProjectOps/ProjectOperationHistory.swift MarkView/Models/ProjectOps/ProjectOperationWrites.swift \
    MarkView/Models/Shared/UserPrompts.swift MarkView/Models/AI/OutputLanguage.swift  tools/tests/ProjectOperationsStoreStubs.swift \
    tools/tests/ScriptedPrompts.swift tools/tests/ProjectOperationsStoreTests.swift
"$app/Contents/MacOS/operations-store-tests"
