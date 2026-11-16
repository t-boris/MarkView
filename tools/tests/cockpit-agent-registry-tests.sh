#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" MarkView/Models/Cockpit/CockpitPlan.swift Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift MarkView/Models/Cockpit/CockpitHostBridge.swift MarkView/Models/Cockpit/CockpitStepPolicy.swift MarkView/Models/Cockpit/CockpitSupervisor.swift MarkView/Models/Cockpit/CockpitAgentRegistry.swift tools/tests/CockpitAgentRegistryChecks.swift
"$out/checks"
