#!/bin/bash
# Verify Phase 1 cleanup and repository hygiene (AR-22, AR-30, AR-44 step 1, AR-46, AR-47, AR-48)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

swiftc -o "$out/phase1-cleanup-tests" tools/tests/Phase1CleanupTests.swift
"$out/phase1-cleanup-tests"
