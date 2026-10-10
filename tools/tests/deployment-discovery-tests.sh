#!/bin/bash
# Checks how Deployments finds where a project runs (MarkView/Models/DeploymentDiscovery.swift,
# DeploymentModels.swift): workflows, platform files, docs, ~/.ssh/config.
#   tools/tests/deployment-discovery-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentDiscoveryTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-discovery-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/DeploymentDiscovery.swift MarkView/Models/ProviderHints.swift "$out/main.swift"
"$out/deployment-discovery-tests"
