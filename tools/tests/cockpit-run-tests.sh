#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CockpitRunChecks.swift "$out/main.swift"
swiftc -o "$out/checks" MarkView/Models/Cockpit/CockpitPlan.swift MarkView/Models/Cockpit/CockpitRun.swift MarkView/Models/Cockpit/CockpitRunStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Cockpit/CockpitSupervisor.swift Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift MarkView/Models/Cockpit/CockpitHostBridge.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/checks"
