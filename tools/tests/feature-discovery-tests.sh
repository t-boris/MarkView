#!/bin/bash
# Checks the discovery rules of a feature (MarkView/Models/FeatureModels.swift MarkView/Models/FeatureVocabulary.swift): when discovery is
# done, the order of open questions, the readiness condition. The app has no XCTest target: the
# module is compiled on its own with a test main and run.
#   tools/tests/feature-discovery-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/FeatureDiscoveryTests.swift "$out/main.swift"
swiftc -O -o "$out/feature-discovery-tests" MarkView/Models/FeatureModels.swift MarkView/Models/FeatureVocabulary.swift MarkView/Models/FrontMatter.swift MarkView/Models/IssueListing.swift "$out/main.swift"
"$out/feature-discovery-tests"
