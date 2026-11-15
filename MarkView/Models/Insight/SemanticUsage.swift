import Foundation

extension CLICompletion.Result {
    /// Add this run to the workspace's usage counter. The write is queued on the database actor; the totals are sums,
    /// so the order of two queued runs does not matter. (The AI layer knows no database: it is the Insight domain that records.)
    func record(in db: SemanticDatabase?) {
        guard let db else { return }
        let input = inputTokens, output = outputTokens, cents = (costUSD ?? 0) * 100
        Task { await db.addUsage(inputTokens: input, outputTokens: output, costCents: cents) }
    }
}
