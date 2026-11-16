#!/bin/bash
# The Logical view of the X-Ray (AR-16 split of ArchitectureStore): the shipping LogicalView on a Modules view as the scanner makes it.
# The architecture models, the clustering and digest types are the shipping files; only the importance rater's data shape and the
# scanner's size limit are stood in (as code-architecture-tests does). No window, no assistant.
#   tools/tests/logical-view-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cat > "$out/Stubs.swift" <<'SWIFT'
import Foundation
enum ArchitectureScanner {
    static let maxParseBytes = 512 * 1024
    static func runTool(_ executable: String, _ arguments: [String]) -> String? { nil }
}
enum ImportanceRater {
    struct Filter: Codable, Hashable { var id: String; var name: String; var criterion: String; var levels: [String] }
    static let importance = Filter(id: "importance", name: "Importance", criterion: "", levels: ["critical", "high", "normal", "low"])
    struct Rating: Codable, Equatable {
        var level: String
        var reason: String
        var signature: String?
        var provisional: Bool?
    }
}
SWIFT
cp tools/tests/LogicalViewTests.swift "$out/main.swift"
swiftc -o "$out/logical-view-tests" -target "$(uname -m)-apple-macos13.0" \
    MarkView/Models/Architecture/LogicalView.swift MarkView/Models/Architecture/ArchitectureModel.swift MarkView/Models/Architecture/CodeArchitecture.swift \
    MarkView/Models/Architecture/CodePathTags.swift MarkView/Models/Architecture/XRayCluster.swift MarkView/Models/Architecture/XRayDigest.swift \
    Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift MarkView/Models/Architecture/AutoAnalysisScheduler.swift \
    MarkView/Models/AI/DiagramAI.swift MarkView/Models/AI/AIOperation.swift tools/tests/DiagramCLIStub.swift "$out/Stubs.swift" "$out/main.swift"
"$out/logical-view-tests"
