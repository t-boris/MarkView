#!/bin/bash
# Checks the bug validity check (MarkView/Models/Lifecycle/BugValidity.swift): the main baseline on real git repositories (a fix only on a branch,
# unpushed commits and uncommitted work never count), the evidence rules that decide whether a bug may be closed, the closure record
# and its retention through later report rewrites, and the order of steps of the three entry points (explicit investigation, answer,
# discussion message). The app has no XCTest target: the module is compiled on its own (with FrontMatter.swift) and run from the
# repository root.
#   tools/tests/bug-validity-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BugValidityTests.swift "$out/main.swift"
swiftc -O -o "$out/bug-validity-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Lifecycle/BugValidity.swift MarkView/Models/Workspace/FrontMatter.swift "$out/main.swift"
"$out/bug-validity-tests"
