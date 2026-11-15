#!/bin/bash
# Checks how Deployments runs commands (MarkView/Models/Deployments/DeploymentExecutor.swift): timeouts, output cap,
# pipes, the ssh command line, and the reading of ssh's errors.
#   tools/tests/deployment-executor-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentExecutorTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-executor-tests" MarkView/Models/AI/CommandPolicy.swift MarkView/Models/Deployments/DeploymentModels.swift MarkView/Models/Deployments/DeploymentExecutor.swift "$out/main.swift"
"$out/deployment-executor-tests"
