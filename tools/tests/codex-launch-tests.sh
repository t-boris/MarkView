#!/bin/bash
# Checks the one-shot launch of Codex (MarkView/Models/AI/Providers/CodexProvider.swift): the answer schema the CLI is told to
# follow (`--output-schema <file>`) is saved whole in the run's scratch folder, each launch has a file of its own, and a scratch
# folder that refuses the file fails the launch without leaving a partial schema or touching an earlier one.
#   tools/tests/codex-launch-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CodexLaunchTests.swift "$out/main.swift"
swiftc -O -o "$out/codex-launch-tests" Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/AI/Providers/*.swift "$out/main.swift"
"$out/codex-launch-tests"
