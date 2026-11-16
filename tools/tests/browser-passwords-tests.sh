#!/bin/bash
# Checks the browser's password manager and download naming (MarkView/Models/Browser/BrowserPasswords.swift,
# BrowserDownloads.swift): host rules, Chrome CSV import, Keychain store under a throwaway domain.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/browser-passwords-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BrowserPasswordsTests.swift "$out/main.swift"
swiftc MarkView/Models/Browser/BrowserAddress.swift -O -o "$out/browser-passwords-tests" Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift MarkView/Models/Browser/BrowserPasswords.swift MarkView/Models/Browser/BrowserDownloads.swift "$out/main.swift"
"$out/browser-passwords-tests"
