#!/bin/bash
# Checks the database explorer (MarkView/Models/DatabaseExplorer.swift): URL parsing without leaking the password, .env
# files, the SQL policy, CSV, and, when Docker and psql are there, a real PostgreSQL: overview, table detail, sample rows,
# read-only enforcement, timeouts, and the store's approval flow.
#   tools/tests/database-explorer-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DatabaseExplorerTests.swift "$out/main.swift"
swiftc -O -o "$out/database-explorer-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/SystemProbe.swift MarkView/Models/DeploymentDiscovery.swift MarkView/Models/DeploymentExecutor.swift MarkView/Models/DeploymentLogs.swift MarkView/Models/DeploymentStore.swift MarkView/Models/DeploymentStore+Databases.swift MarkView/Models/DatabaseExplorer.swift MarkView/Models/DatabaseKeychain.swift "$out/main.swift"
"$out/database-explorer-tests"
