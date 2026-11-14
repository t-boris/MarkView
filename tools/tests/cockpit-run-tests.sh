#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CockpitRunChecks.swift "$out/main.swift"
swiftc -o "$out/checks" MarkView/Models/CockpitPlan.swift MarkView/Models/CockpitRun.swift MarkView/Models/CockpitRunStore.swift MarkView/Models/CockpitSupervisor.swift MarkView/Models/CockpitHostBridge.swift "$out/main.swift"
"$out/checks"
