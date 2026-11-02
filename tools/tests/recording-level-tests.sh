#!/bin/bash
# Checks how loud a recording is (RecordingLevel in MarkView/Models/RecordingLevel.swift): the peak of
# a 16-bit WAV as AVAudioRecorder writes it, and when that counts as the microphone delivering
# silence. Only the pure enum is compiled, not the app.
#   tools/tests/recording-level-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp MarkView/Models/RecordingLevel.swift "$out/Level.swift"
cp tools/tests/RecordingLevelTests.swift "$out/main.swift"
swiftc -O -o "$out/recording-level-tests" "$out/Level.swift" "$out/main.swift"
"$out/recording-level-tests"
