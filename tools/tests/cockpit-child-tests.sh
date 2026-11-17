#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/checks" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Cockpit/CockpitChild.swift tools/tests/CockpitChildChecks.swift
"$out/checks"
