#!/bin/bash
# Checks where Prototype Studio keeps the images it sends (MarkView/Models/PrototypeImages.swift): the saved attachment file.
# Converting, shrinking and reading images is shared with UI Studio and checked by image-attachments-tests.sh.
#   tools/tests/prototype-images-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrototypeImagesTests.swift "$out/main.swift"
swiftc -O -o "$out/prototype-images-tests" MarkView/Models/ImageAttachments.swift MarkView/Models/PrototypeImages.swift "$out/main.swift"
"$out/prototype-images-tests"
