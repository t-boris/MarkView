#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/workspace-redesign-tests" \
    MarkView/Models/FrontMatter.swift \
    MarkView/Models/SpecificationHandoff.swift \
    MarkView/Models/ProjectSearch.swift \
    MarkView/Models/ProjectChangeReview.swift \
    tools/tests/WorkspaceRedesignTests.swift
"$out/workspace-redesign-tests"
