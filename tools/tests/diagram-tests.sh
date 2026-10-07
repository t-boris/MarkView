#!/bin/bash
# Checks DiagramAI's validation and Mermaid output (MarkView/Models/DiagramAI.swift). The app has no
# XCTest target: the module is compiled on its own, with a stand-in for CLICompletion, and run.
#   tools/tests/diagram-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/DiagramAITests.swift "$out/main.swift"
swiftc -O -o "$out/diagram-tests" MarkView/Models/DiagramAI.swift tools/tests/DiagramCLIStub.swift "$out/main.swift"
"$out/diagram-tests"
