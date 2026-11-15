#!/bin/bash
# The file-system scans a window runs off the main thread (AR-42): the Markdown probe, the diagram sheet's document list,
# the by-name lookup of a search result, and the open-files watcher's read. Compiles the shipping BackgroundFileScans.swift
# with checks that run on real folders.
#   tools/tests/background-file-scans-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BackgroundFileScansTests.swift "$out/main.swift"
swiftc -O -o "$out/check" MarkView/Models/Workspace/BackgroundFileScans.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift "$out/main.swift"
"$out/check"
