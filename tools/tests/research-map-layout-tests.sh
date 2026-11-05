#!/bin/bash
# The research map's layout engine (DEC-007): presets, inheritance, nested layouts, manual positions and the
# guarantee that no two node boxes overlap. Pure JavaScript, run with node (no packages).
#   tools/tests/research-map-layout-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
node tools/tests/research-map-layout.test.js
