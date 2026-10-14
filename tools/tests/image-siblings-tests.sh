#!/bin/bash
# Checks stepping through a folder's images (ImageSiblings.swift).
#   tools/tests/image-siblings-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ImageSiblingsTests.swift "$out/main.swift"
swiftc -o "$out/image-siblings-tests" MarkView/Models/ImageSiblings.swift "$out/main.swift"
"$out/image-siblings-tests"
