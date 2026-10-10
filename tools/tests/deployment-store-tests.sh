#!/bin/bash
# Checks the Deployments store (MarkView/Models/DeploymentStore.swift): saving, looking at a machine, running commands
# with the read-only / approval / blocked rules, the command log, proposals.
#   tools/tests/deployment-store-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentStoreTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-store-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/SystemProbe.swift MarkView/Models/DeploymentDiscovery.swift MarkView/Models/DeploymentExecutor.swift MarkView/Models/DeploymentStore.swift "$out/main.swift"
"$out/deployment-store-tests"
