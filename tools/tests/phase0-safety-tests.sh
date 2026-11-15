#!/bin/bash
# Phase 0 safety and correctness checks (AR-01 through AR-13).
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -target arm64-apple-macosx13.0 \
    tools/tests/Phase0SafetyTests.swift \
    -o "$out/phase0-safety-tests"

"$out/phase0-safety-tests"
