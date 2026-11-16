#!/bin/bash
# Checks the AI call log (MarkView/Models/AI/AICallLog.swift): a line per call is appended to Application Support/MarkView/ai-calls.jsonl
# through AtomicFile.append, in order, from several threads without losing one, and a log that cannot be written keeps its lines.
#   tools/tests/ai-call-log-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AICallLogTests.swift "$out/main.swift"
swiftc -O -o "$out/ai-call-log-tests" Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/AI/AICallLog.swift "$out/main.swift"
# CFFIXED_USER_HOME moves Application Support into the scratch folder: the person's own log is never touched.
CFFIXED_USER_HOME="$out/home" "$out/ai-call-log-tests"
