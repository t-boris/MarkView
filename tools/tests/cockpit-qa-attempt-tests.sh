#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" MarkView/Models/Cockpit/CockpitPlan.swift MarkView/Models/Cockpit/CockpitQAAttempt.swift MarkView/Models/Workspace/ToolRegistry.swift tools/tests/CockpitQAAttemptChecks.swift
"$out/checks"
