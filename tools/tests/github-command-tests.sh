#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/github-command-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Git/GitHubClient.swift MarkView/Models/Lifecycle/EvidenceTimings.swift \
    MarkView/Models/Lifecycle/LifecycleCapture.swift tools/tests/GitHubCommandTests.swift
"$out/github-command-tests"
