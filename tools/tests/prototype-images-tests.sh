#!/bin/bash
# Checks the images of Prototype Studio (MarkView/Models/PrototypeImages.swift): PNG conversion and shrinking,
# images and image files read from a pasteboard, and the saved attachment file.
#   tools/tests/prototype-images-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeImagesTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-images-tests" MarkView/Models/PrototypeImages.swift "$out/main.swift"
"$out/prototype-images-tests"
