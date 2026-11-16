#!/bin/bash
# Checks who owns the work the Git tab starts (AR-19): the shipping GitClient (looks, operations, the commit receipt, transfers) over a
# real temporary repository with a bare origin, and the shipping GitHubStore jobs (start, restart, reset) with stand-in work. A tap starts
# work the model keeps; a restart replaces it, a close cancels it, nothing is written after the close. `gh` is never run.
#   tools/tests/git-task-ownership-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/git-task-ownership-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Git/GitClient.swift MarkView/Models/Git/GitHubStore.swift MarkView/Models/Git/GitHubClient.swift \
    MarkView/Models/Git/GitStatusModel.swift tools/tests/CLIToolLocatorStub.swift tools/tests/GitStoreStubs.swift tools/tests/GitTaskOwnershipTests.swift
"$out/git-task-ownership-tests"
