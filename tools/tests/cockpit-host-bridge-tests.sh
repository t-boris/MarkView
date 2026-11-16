#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" MarkView/Models/Cockpit/CockpitPlan.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift MarkView/Models/Cockpit/CockpitHostBridge.swift tools/tests/CockpitHostBridgeChecks.swift
"$out/checks"
