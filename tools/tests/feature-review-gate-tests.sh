#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/FeatureReviewGateChecks.swift "$out/main.swift"
swiftc -o "$out/checks" MarkView/Models/FeatureReviewGate.swift "$out/main.swift"
"$out/checks"
