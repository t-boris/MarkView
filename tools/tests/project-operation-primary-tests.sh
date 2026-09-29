#!/bin/bash
# Checks which project operations get a button up front (ProjectOperation.primary). The app has no
# XCTest target: the model file is compiled on its own with a test main and run.
#   tools/tests/project-operation-primary-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/ProjectOperationPrimaryTests.swift "$out/main.swift"
# The model keeps unknown JSON keys as AnyCodable (defined with the bridge); the fixtures have none.
cat > "$out/Stub.swift" <<'SWIFT'
struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}
SWIFT
swiftc -O -o "$out/primary-tests" MarkView/Models/ProjectOperation.swift "$out/Stub.swift" "$out/main.swift"
"$out/primary-tests"
