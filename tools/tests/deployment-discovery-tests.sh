#!/bin/bash
# Checks how Deployments finds where a project runs (MarkView/Models/Deployments/DeploymentDiscovery.swift,
# DeploymentModels.swift): workflows, platform files, docs, ~/.ssh/config.
#   tools/tests/deployment-discovery-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentDiscoveryTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-discovery-tests" Packages/MarkViewCore/Sources/MarkViewCore/CommandPolicy.swift MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/Deployments/DeploymentDiscovery.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/AI/ProviderHints.swift "$out/main.swift"
"$out/deployment-discovery-tests"
