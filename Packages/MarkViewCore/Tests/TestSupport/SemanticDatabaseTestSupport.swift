import Foundation

/// Shared stand-in for the usage and document-ID operations needed by standalone suites.
actor SemanticDatabase {
    private(set) var usage: [(input: Int, output: Int, cents: Double)] = []
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {
        usage.append((inputTokens, outputTokens, costCents))
    }
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
