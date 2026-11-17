#!/bin/bash
# Checks who owns the work the Deployments tab starts (AR-19): the shipping DeploymentStore with the real local executor. A tap starts
# work the store keeps; a restart replaces it, a close ends it together with its process, and nothing is written after the close.
# The slow commands are `cat` on a named pipe and `sleep`, in a temporary folder; nothing leaves the machine.
#   tools/tests/deployment-task-ownership-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentTaskOwnershipTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-task-ownership-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/Deployments/SystemProbe.swift MarkView/Models/Deployments/DeploymentDiscovery.swift MarkView/Models/Deployments/DeploymentExecutor.swift MarkView/Models/Deployments/DeploymentLogs.swift MarkView/Models/Deployments/CloudServices.swift MarkView/Models/AI/ProviderHints.swift MarkView/Models/Deployments/DeploymentStore.swift MarkView/Models/Shared/SchemaVersionedStore.swift MarkView/Models/Deployments/DeploymentStore+Databases.swift MarkView/Models/Deployments/DatabaseExplorer.swift MarkView/Models/Deployments/DatabaseKeychain.swift "$out/main.swift"
"$out/deployment-task-ownership-tests"
