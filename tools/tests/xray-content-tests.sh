#!/bin/bash
# Checks sparse and useful X-Ray content hierarchy from local and AI outlines.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/XRayContentTests.swift "$out/main.swift"
swiftc -o "$out/xray-content-tests" MarkView/Models/XRayContent.swift "$out/main.swift"
"$out/xray-content-tests"
