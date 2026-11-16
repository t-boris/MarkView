#!/bin/bash
# What an X-Ray page may ask of the window (MarkView/Models/Architecture/XRayCommand.swift, AR-14 step 11): the action-to-command routing,
# what is dropped before it reaches a store, the operations-strip scope rule and the containment of the files a page names.
# Compiles the shipping XRayCommand; the dispatcher that performs a command is covered by the app probe.
#   tools/tests/xray-command-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/xray-command-tests" MarkView/Models/Architecture/XRayCommand.swift tools/tests/XRayCommandTests.swift
"$out/xray-command-tests"
