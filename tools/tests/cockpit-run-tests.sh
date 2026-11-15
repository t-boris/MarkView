#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CockpitRunChecks.swift "$out/main.swift"
swiftc -o "$out/checks" MarkView/Models/Cockpit/CockpitPlan.swift MarkView/Models/Cockpit/CockpitRun.swift MarkView/Models/Cockpit/CockpitRunStore.swift MarkView/Models/Cockpit/CockpitSupervisor.swift MarkView/Models/Cockpit/CockpitHostBridge.swift "$out/main.swift"
"$out/checks"
