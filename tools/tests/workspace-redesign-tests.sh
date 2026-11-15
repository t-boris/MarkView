#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# ProjectSearch reads linked folders; their CLI and database helpers are stubbed as in linked-folders-tests.sh.
cat > "$out/Stubs.swift" <<'SWIFT'
import Foundation
enum CLITool { case claude, codex, cline, copilot }
enum SemanticDatabase {
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) { return String(filePath.dropFirst(prefix.count)) }
        return fileURL.lastPathComponent
    }
}
SWIFT
swiftc -parse-as-library -o "$out/workspace-redesign-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Workspace/FrontMatter.swift \
    MarkView/Models/Lifecycle/SpecificationHandoff.swift \
    MarkView/Models/Workspace/ProjectSearch.swift \
    MarkView/Models/Workspace/ArchiveSupport.swift \
    MarkView/Models/Workspace/LinkedFolders.swift \
    MarkView/Models/Appearance/ProjectColor.swift \
    "$out/Stubs.swift" \
    MarkView/Models/Architecture/ProjectChangeReview.swift \
    tools/tests/WorkspaceRedesignTests.swift
"$out/workspace-redesign-tests"
