#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" MarkView/Models/AgentProcesses.swift MarkView/Models/CockpitChild.swift tools/tests/CockpitChildChecks.swift
"$out/checks"
