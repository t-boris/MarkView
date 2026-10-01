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
swiftc -parse-as-library -o "$out/workspace-redesign-tests" \
    MarkView/Models/FrontMatter.swift \
    MarkView/Models/SpecificationHandoff.swift \
    MarkView/Models/ProjectSearch.swift \
    MarkView/Models/LinkedFolders.swift \
    MarkView/Models/ProjectColor.swift \
    "$out/Stubs.swift" \
    MarkView/Models/ProjectChangeReview.swift \
    tools/tests/WorkspaceRedesignTests.swift
"$out/workspace-redesign-tests"
