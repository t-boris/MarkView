#!/bin/bash
# The pictures a research map node carries beside its icon (REQ-017, DEC-018): the kind of a picture from its bytes,
# the size limit, and a safe unique file name beside the map.
#   tools/tests/research-map-images-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ResearchMapImagesTests.swift "$out/main.swift"
swiftc -O -o "$out/research-map-images-tests" MarkView/Models/ResearchMapImages.swift "$out/main.swift"
"$out/research-map-images-tests"
