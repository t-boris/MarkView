#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" \
    MarkView/Models/TerminalChildProcess.swift tools/tests/TerminalChildProcessTests.swift \
    -o "$out/terminal-child-tests"
"$out/terminal-child-tests"
