#!/bin/bash
# Checks the database explorer (MarkView/Models/Deployments/DatabaseExplorer.swift): URL parsing without leaking the password, .env
# files, the SQL policy, CSV, and, when Docker and psql are there, a real PostgreSQL: overview, table detail, sample rows,
# read-only enforcement, timeouts, and the store's approval flow.
#   tools/tests/database-explorer-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DatabaseExplorerTests.swift "$out/main.swift"
swiftc -O -o "$out/database-explorer-tests" MarkView/Models/AI/CommandPolicy.swift MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/AI/SystemProbe.swift MarkView/Models/Deployments/DeploymentDiscovery.swift MarkView/Models/Deployments/DeploymentExecutor.swift MarkView/Models/Deployments/DeploymentLogs.swift MarkView/Models/Deployments/CloudServices.swift MarkView/Models/AI/ProviderHints.swift MarkView/Models/Deployments/DeploymentStore.swift MarkView/Models/Deployments/DeploymentStore+Databases.swift MarkView/Models/Deployments/DatabaseExplorer.swift MarkView/Models/Deployments/DatabaseKeychain.swift "$out/main.swift"
"$out/database-explorer-tests"
