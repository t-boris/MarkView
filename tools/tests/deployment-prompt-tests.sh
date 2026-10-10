#!/bin/bash
# Checks the prompt that sends the assistant to find where the project runs (MarkView/Models/DeploymentPrompt.swift).
#   tools/tests/deployment-prompt-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DeploymentPromptTests.swift "$out/main.swift"
swiftc -O -o "$out/deployment-prompt-tests" MarkView/Models/DeploymentPrompt.swift "$out/main.swift"
"$out/deployment-prompt-tests"
