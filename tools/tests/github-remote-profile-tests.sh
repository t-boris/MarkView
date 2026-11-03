#!/bin/bash
# Checks how a Git remote is recognized as GitHub (MarkView/Models/GitHubClient.swift): SSH host
# aliases from ~/.ssh/config, and the per-folder `gh` configuration directory a .ghprofile selects.
# The app has no XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/github-remote-profile-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/github-remote-profile-tests" \
    MarkView/Models/GitHubClient.swift MarkView/Models/LifecycleAnalytics.swift \
    MarkView/Models/LifecycleCapture.swift tools/tests/CLIToolLocatorStub.swift \
    tools/tests/GitHubRemoteProfileTests.swift
"$out/github-remote-profile-tests"
