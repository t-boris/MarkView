#!/bin/bash
# Checks how Deployments runs commands (MarkView/Models/DeploymentExecutor.swift): timeouts, output cap,
# pipes, the ssh command line, and the reading of ssh's errors.
#   tools/tests/deployment-executor-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentExecutorTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-executor-tests" MarkView/Models/CommandPolicy.swift MarkView/Models/DeploymentModels.swift MarkView/Models/DeploymentExecutor.swift "$out/main.swift"
"$out/deployment-executor-tests"
