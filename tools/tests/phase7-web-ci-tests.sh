#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

BIN="/tmp/markview-phase7-web-ci-tests"
swiftc -O \
  tools/tests/Phase7WebCITests.swift \
  -o "$BIN"

"$BIN"
