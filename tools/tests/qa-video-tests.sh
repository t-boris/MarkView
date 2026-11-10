#!/bin/bash
# Feature end-to-end-qa: the video of a QA run (Models/QAVideoWriter.swift): pictures that arrive every few seconds become a constant
# frame rate H.264 .mp4 with a subtitle band under the picture. Every video is written offscreen to a temp folder and read back with
# AVAssetReader; no window is opened and no Screen Recording permission is needed. Compiled on its own with a test main (no XCTest
# target exists), for the macOS 13 deployment target so that only APIs the app can use are called.
#   tools/tests/qa-video-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/QAVideoChecks.swift "$out/main.swift"
swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$out/qa-video-checks" MarkView/Models/QAVideoWriter.swift "$out/main.swift"
"$out/qa-video-checks"
