#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
node tools/tests/process-graph-layout-tests.mjs
