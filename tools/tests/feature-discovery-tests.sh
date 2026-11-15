#!/bin/bash
# Checks the discovery rules of a feature (MarkView/Models/Lifecycle/FeatureModels.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift): when discovery is
# done, the order of open questions, the readiness condition. The app has no XCTest target: the
# module is compiled on its own with a test main and run.
#   tools/tests/feature-discovery-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/FeatureDiscoveryTests.swift "$out/main.swift"
swiftc -O -o "$out/feature-discovery-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Lifecycle/FeatureModels.swift MarkView/Models/Lifecycle/FeatureVocabulary.swift MarkView/Models/Workspace/FrontMatter.swift MarkView/Models/Lifecycle/IssueListing.swift MarkView/Models/Lifecycle/ProjectWorkflow.swift MarkView/Models/Lifecycle/IssueLifecycle.swift MarkView/Models/Lifecycle/BugValidity.swift "$out/main.swift"
"$out/feature-discovery-tests"
