#!/bin/bash
# Checks the logs Deployments offers without setup (MarkView/Models/DeploymentLogs.swift).
#   tools/tests/deployment-logs-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentLogsTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-logs-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/SystemProbe.swift MarkView/Models/DeploymentLogs.swift "$out/main.swift"
"$out/deployment-logs-tests"
