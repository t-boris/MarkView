#!/bin/bash
# Checks the read-only / confirm / never policy for commands run on servers and cloud CLIs
# (MarkView/Models/CommandPolicy.swift).
#   tools/tests/command-policy-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CommandPolicyTests.swift "$out/main.swift"
swiftc -O -o "$out/command-policy-tests" MarkView/Models/CommandPolicy.swift "$out/main.swift"
"$out/command-policy-tests"
