import Foundation

@main struct Checks {
    @MainActor static func main() {
        let root = URL(fileURLWithPath: "/tmp/project-a"), other = URL(fileURLWithPath: "/tmp/project-b")
        var replies: [CockpitHostReply] = []
        let ticket = CockpitAgentRegistry.register(root: root) { replies.append($0) }
        let result = CockpitHostResult(passed: true, detail: "Done", build: "b1")
        guard !CockpitAgentRegistry.complete(root: other, token: ticket, result: result), replies.isEmpty else { fatalError("cross-project report accepted") }
        let long = CockpitHostResult(passed: true, detail: String(repeating: "x", count: 32_001), build: "")
        guard !CockpitAgentRegistry.complete(root: root, token: ticket, result: long), replies.isEmpty else { fatalError("oversized report accepted") }
        guard CockpitAgentRegistry.complete(root: root, token: ticket, result: result), replies.count == 1,
              !CockpitAgentRegistry.complete(root: root, token: ticket, result: result) else { fatalError("ticket was not one-use") }
        let interrupted = CockpitAgentRegistry.register(root: root) { replies.append($0) }
        CockpitAgentRegistry.cancel(interrupted, reason: "Stopped")
        CockpitAgentRegistry.cancel(interrupted, reason: "Again")
        guard replies.count == 2, replies[1].error == "Stopped" else { fatalError("cancellation was not one-use") }
        print("Cockpit agent ticket checks passed")
    }
}
