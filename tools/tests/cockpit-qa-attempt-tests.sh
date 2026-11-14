#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" MarkView/Models/CockpitPlan.swift MarkView/Models/CockpitQAAttempt.swift tools/tests/CockpitQAAttemptChecks.swift
"$out/checks"
