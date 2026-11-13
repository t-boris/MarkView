#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CockpitPlanningChecks.swift "$out/main.swift"
swiftc -o "$out/checks" MarkView/Models/CockpitPlan.swift MarkView/Models/CockpitPlanning.swift "$out/main.swift"
"$out/checks"
