#!/bin/bash
# AR-18: the settings registry (Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift) against the names an earlier build wrote
# to the person's preferences: one row per key (and per family instance) with its old name, scope, value type and default, and the
# behavior: an old value is read through the key, a value written through the key lands under the old name. Also checks that every key
# in the registry source has a row.
#   tools/tests/settings-key-table-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/SettingsKeyTableTests.swift "$out/main.swift"
swiftc -suppress-warnings -module-cache-path /private/tmp/markview-swift-cache -o "$out/settings-key-table-tests" \
  Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift "$out/main.swift"
"$out/settings-key-table-tests" "$PWD/Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift"
