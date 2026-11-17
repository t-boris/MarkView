import Foundation

/// Shared stand-in for the session identity and cancellation used by standalone window tests.
struct InsightSession {
    let id = UUID()
    func cancel() async {}
}
