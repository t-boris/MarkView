#!/bin/bash
# Checks the logs Deployments offers without setup (MarkView/Models/Deployments/DeploymentLogs.swift).
#   tools/tests/deployment-logs-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentLogsTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-logs-tests" Packages/MarkViewCore/Sources/MarkViewCore/CommandPolicy.swift MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/Deployments/SystemProbe.swift MarkView/Models/Deployments/DeploymentLogs.swift "$out/main.swift"
"$out/deployment-logs-tests"
