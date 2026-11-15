#!/bin/bash
# The Finder Quick Action request poll (Models/Workspace/FinderOpenRequests.swift) on real files in a temporary folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -o "$out/finder-open-requests-tests" \
    MarkView/Models/Workspace/TaskBag.swift MarkView/Models/Workspace/FinderOpenRequests.swift tools/tests/FinderOpenRequestsTests.swift
"$out/finder-open-requests-tests"
