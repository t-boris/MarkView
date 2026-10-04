#!/bin/bash
# Checks the MCP server agents use to drive MarkView's browser tab (MarkView/Models/BrowserAgentTools.swift):
# MCP answers, and a real `--mcp-browser` process relaying a call over a Unix socket. The app has no
# XCTest target: the module is compiled on its own with a test main and run.
#   tools/tests/browser-agent-tools-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/BrowserAgentToolsTests.swift "$out/main.swift"
swiftc -O -o "$out/browser-agent-tools-tests" MarkView/Models/BrowserAgentTools.swift "$out/main.swift"
"$out/browser-agent-tools-tests"
