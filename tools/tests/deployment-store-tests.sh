#!/bin/bash
# Checks the Deployments store (MarkView/Models/Deployments/DeploymentStore.swift MarkView/Models/Deployments/DeploymentStore+Databases.swift MarkView/Models/Deployments/DatabaseExplorer.swift MarkView/Models/Deployments/DatabaseKeychain.swift): saving, looking at a machine, running commands
# with the read-only / approval / blocked rules, the command log, proposals.
#   tools/tests/deployment-store-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentStoreTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-store-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/AI/CommandPolicy.swift MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/AI/SystemProbe.swift MarkView/Models/Deployments/DeploymentDiscovery.swift MarkView/Models/Deployments/DeploymentExecutor.swift MarkView/Models/Deployments/DeploymentLogs.swift MarkView/Models/Deployments/CloudServices.swift MarkView/Models/AI/ProviderHints.swift MarkView/Models/Deployments/DeploymentStore.swift MarkView/Models/Workspace/SchemaVersionedStore.swift MarkView/Models/Deployments/DeploymentStore+Databases.swift MarkView/Models/Deployments/DatabaseExplorer.swift MarkView/Models/Deployments/DatabaseKeychain.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/deployment-store-tests"
