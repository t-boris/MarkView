import Foundation

// Compile-time stand-ins for what the hand-off run names and the checks never exercise: the feature store and the writer that applies a plan
// to it. The writer here waits for the check to let it go and says how it ended, so that the run's own start, refusal of a second press and
// outcome can be checked (the real writer is checked with the feature store, which these checks do not build).

@MainActor final class FeatureStore {}

@MainActor enum PrototypeFeatureWriter {
    struct Created: Equatable {
        var slug: String
        var overview: URL
        var requirements: Int
        var pictures: Int
        var skipped: [String]
    }

    struct Failure: Error, LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// How many times a feature was asked to be written.
    static var writes = 0
    /// Set by a check to make the next write fail, or to hold it until `release` is called.
    static var failure: String?
    static var gate: CheckedContinuation<Void, Never>?
    static var hold = false

    static func release() { gate?.resume(); gate = nil; hold = false }

    static func write(_ plan: PrototypeHandoff.FeaturePlan, into store: FeatureStore) async throws -> Created {
        writes += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        if let failure { throw Failure(message: failure) }
        return Created(slug: "shop-sync", overview: URL(fileURLWithPath: "/tmp/shop-sync.md"), requirements: plan.requirements.count, pictures: 0, skipped: [])
    }
}
