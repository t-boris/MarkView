import Foundation

@main struct Checks {
    @MainActor static func main() async {
        let root = URL(fileURLWithPath: "/tmp/project-a"), other = URL(fileURLWithPath: "/tmp/project-b")
        var replies: [CockpitHostReply] = []
        var progressReports: [CockpitProgress] = []
        let ticket = CockpitAgentRegistry.register(root: root, progress: { progressReports.append($0) }) { replies.append($0) }
        let progress = CockpitProgress(passNumber: 2, activity: "Testing", scenarioCoverage: ["checkout"], bugs: ["BUG-1"], fixes: [], latestChange: "Changed", blockers: [], buildLogPath: "build/log.txt")
        guard !(await CockpitAgentRegistry.report(root: other, token: ticket, progress: progress)),
              await CockpitAgentRegistry.report(root: root, token: ticket, progress: progress), progressReports == [progress] else { fatalError("progress was not project-scoped") }
        var invalid = progress; invalid.passNumber = 0
        guard !(await CockpitAgentRegistry.report(root: root, token: ticket, progress: invalid)) else { fatalError("invalid pass accepted") }
        invalid = progress; invalid.activity = String(repeating: "x", count: 16_001)
        guard !(await CockpitAgentRegistry.report(root: root, token: ticket, progress: invalid)) else { fatalError("oversized progress accepted") }
        let result = CockpitHostResult(passed: true, detail: "Done", build: "b1")
        guard !CockpitAgentRegistry.complete(root: other, token: ticket, result: result), replies.isEmpty else { fatalError("cross-project report accepted") }
        let long = CockpitHostResult(passed: true, detail: String(repeating: "x", count: 32_001), build: "")
        guard !CockpitAgentRegistry.complete(root: root, token: ticket, result: long), replies.isEmpty else { fatalError("oversized report accepted") }
        guard CockpitAgentRegistry.complete(root: root, token: ticket, result: result), replies.count == 1,
              !CockpitAgentRegistry.complete(root: root, token: ticket, result: result) else { fatalError("ticket was not one-use") }
        guard !(await CockpitAgentRegistry.report(root: root, token: ticket, progress: progress)) else { fatalError("expired ticket accepted progress") }
        let unsaved = CockpitAgentRegistry.register(root: root, progress: { _ in throw NSError(domain: "test", code: 1) }) { replies.append($0) }
        guard !(await CockpitAgentRegistry.report(root: root, token: unsaved, progress: progress)) else { fatalError("failed persistence was acknowledged") }
        CockpitAgentRegistry.cancel(unsaved, reason: "Unavailable")
        let interrupted = CockpitAgentRegistry.register(root: root) { replies.append($0) }
        CockpitAgentRegistry.cancel(interrupted, reason: "Stopped")
        CockpitAgentRegistry.cancel(interrupted, reason: "Again")
        guard replies.count == 3, replies[2].error == "Stopped" else { fatalError("cancellation was not one-use") }
        _ = CockpitAgentRegistry.register(root: root) { replies.append($0) }
        _ = CockpitAgentRegistry.register(root: other) { replies.append($0) }
        CockpitAgentRegistry.cancelAll(reason: "Closing")
        guard replies.count == 5, replies.suffix(2).allSatisfy({ $0.error == "Closing" }) else { fatalError("app close did not stop every cockpit assignment") }
        var waited = false
        _ = CockpitAgentRegistry.register(root: root, waitForShutdown: { waited = true }) { replies.append($0) }
        await CockpitAgentRegistry.cancelAllAndWait(reason: "Quitting")
        guard waited, replies.last?.error == "Quitting" else { fatalError("quit did not wait for terminal shutdown") }
        print("Cockpit agent ticket checks passed")
    }
}
