#!/bin/bash
# The readings of the Cockpit instrument panel (Models/CockpitInstruments.swift): altitude, distance, fuel, turns, wind, pulse and the
# lamps, computed from a run. Foundation only; compiled on its own with a test main (no XCTest target exists). Run from anywhere:
#   tools/tests/cockpit-instruments-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/CockpitInstrumentsChecks.swift "$out/main.swift"
swiftc -o "$out/checks" "$M/Cockpit/CockpitPlan.swift" "$M/Cockpit/CockpitRun.swift" "$M/Cockpit/CockpitSupervisor.swift" Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift "$M/Cockpit/CockpitHostBridge.swift" "$M/Cockpit/CockpitInstruments.swift" "$out/main.swift"
"$out/checks"
