#!/bin/bash
# Checks the parser behind the Git tab (MarkView/Models/GitStatusModel.swift) on hand-written
# `git status --porcelain=v2 -z` output and on a real temporary repository.
#   tools/tests/git-status-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/GitStatusTests.swift "$out/main.swift"
swiftc -O -o "$out/git-status-tests" MarkView/Models/GitStatusModel.swift "$out/main.swift"
"$out/git-status-tests"
