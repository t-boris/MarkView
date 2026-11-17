/// The minimal store identity and fixed date used by standalone window and X-Ray checks.
@MainActor final class FeatureStore {
    nonisolated static var today: String { "2026-01-01" }
}
