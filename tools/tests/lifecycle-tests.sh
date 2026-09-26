#!/bin/bash
# Checks the lifecycle duration rules (MarkView/Models/LifecycleAnalytics.swift) and the automatic
# capture parsing (LifecycleCapture.swift). The app has
# no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/lifecycle-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/LifecycleAnalyticsTests.swift "$out/main.swift"
swiftc -O -o "$out/lifecycle-tests" MarkView/Models/LifecycleAnalytics.swift MarkView/Models/LifecycleCapture.swift "$out/main.swift"
"$out/lifecycle-tests"
