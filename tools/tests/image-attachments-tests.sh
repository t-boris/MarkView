#!/bin/bash
# Checks the images of the request boxes of Prototype Studio and UI Studio (MarkView/Models/ImageAttachments.swift): PNG
# normalisation and the 1600 px downscale, images read from a pasteboard, a file or a drop, the limits of a request (six
# images, 8 MB each) with the notice for what is refused, the name of the saved file, and a paste of text at the caret.
#   tools/tests/image-attachments-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ImageAttachmentsTests.swift "$out/main.swift"
swiftc -O -o "$out/image-attachments-tests" MarkView/Models/ImageAttachments.swift "$out/main.swift"
"$out/image-attachments-tests"
