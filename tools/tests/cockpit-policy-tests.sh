#!/bin/bash
# Cockpit step policy and controls: which MarkView tools a Cockpit step may call under the approved controls, that every MarkView
# tool is classified, and how saved free-text limits are read (Models/CockpitStepPolicy.swift, the controls in CockpitPlan.swift).
# Foundation only; compiled on its own with a test main (no XCTest target exists). Run from anywhere:
#   tools/tests/cockpit-policy-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/CockpitPolicyChecks.swift "$out/main.swift"
swiftc -O -o "$out/cockpit-policy" "$M/CockpitPlan.swift" "$M/CockpitStepPolicy.swift" "$M/CockpitStepAudit.swift" "$M/CockpitStepMeter.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/cockpit-policy"
