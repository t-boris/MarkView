#!/bin/bash
# What the person starts from the panels of a project runs as a keyed job of the project's store (AR-19): the shipping FeatureJobs over
# the shipping TaskBag. A start while the job runs is refused, and cancelAll (the folder switching or the window closing) ends
# every job without a write after it.
#   tools/tests/feature-jobs-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -target "$(uname -m)-apple-macos13.0" -o "$out/feature-jobs-tests" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift MarkView/Models/Lifecycle/FeatureJobs.swift tools/tests/FeatureJobsChecks.swift
"$out/feature-jobs-tests"
