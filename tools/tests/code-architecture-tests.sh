#!/bin/bash
# Pure architecture validation and a real WebKit exercise of the shipping X-Ray.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/CodeArchitectureTests.swift "$out/main.swift"
swiftc -O -o "$out/check" MarkView/Models/ArchitectureModel.swift MarkView/Models/CodeArchitecture.swift MarkView/Models/CodePathTags.swift \
  MarkView/Models/DiagramAI.swift tools/tests/DiagramCLIStub.swift tools/tests/CodeArchitectureTestSupport.swift "$out/main.swift"
"$out/check" "$PWD/tools/tests/fixtures/code-architecture" "$out"
if [[ "${1:-}" == "--model-only" ]]; then exit 0; fi
cp tools/tests/CodeArchitectureWebTests.swift "$out/main.swift"
swiftc -O -o "$out/web" "$out/main.swift"
"$out/web" "$PWD/MarkView/Resources/Editor" "$out/payload.json"
