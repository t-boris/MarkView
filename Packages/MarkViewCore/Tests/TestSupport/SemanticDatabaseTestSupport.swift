import Foundation

/// Shared stand-in for the usage and document-ID operations needed by standalone suites.
actor SemanticDatabase {
    private(set) var usage: [(input: Int, output: Int, cents: Double)] = []
    var snapshotData: Data?
    var snapshotSaves = 0
    var reviews: [String: String] = [:]
    var reviewSaves = 0
    private(set) var usageRuns = 0
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {
        usage.append((inputTokens, outputTokens, costCents))
        usageRuns += 1
    }
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : fileURL.lastPathComponent
    }
}
