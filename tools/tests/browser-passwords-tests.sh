#!/bin/bash
# Checks the browser's password manager and download naming (MarkView/Models/BrowserPasswords.swift,
# BrowserDownloads.swift): host rules, Chrome CSV import, Keychain store under a throwaway domain.
# The app has no XCTest target: the modules are compiled on their own with a test main and run.
#   tools/tests/browser-passwords-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BrowserPasswordsTests.swift "$out/main.swift"
swiftc -O -o "$out/browser-passwords-tests" MarkView/Models/BrowserPasswords.swift MarkView/Models/BrowserDownloads.swift "$out/main.swift"
"$out/browser-passwords-tests"
