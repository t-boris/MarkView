#!/bin/bash
# BUG-111: the Logical view's top level flows to the right or downwards, whichever fills the canvas better, so a chain of components
# is not a thin strip of unreadable labels. The shipping X-Ray page is loaded off screen in WebKit.
#   tools/tests/xray-layout-web-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/XRayLayoutWebTests.swift "$out/main.swift"
swiftc -O -o "$out/web" "$out/main.swift"
"$out/web" "$PWD/MarkView/Resources/Editor"
