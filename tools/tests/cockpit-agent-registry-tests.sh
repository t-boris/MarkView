#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" MarkView/Models/CockpitHostBridge.swift MarkView/Models/CockpitAgentRegistry.swift tools/tests/CockpitAgentRegistryChecks.swift
"$out/checks"
