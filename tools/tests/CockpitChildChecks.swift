import Foundation

@main struct Checks {
    static func main() async throws {
        let (child, line) = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"ready\":true}\\n'; cat >/dev/null"], timeout: 3)
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Bool], json["ready"] == true else { fatalError("readiness was not read") }
        child.stop()
        for _ in 0..<100 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        guard AgentProcesses.count == 0 else { fatalError("helper did not stop on EOF") }
        do {
            _ = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 1"], timeout: 3)
            fatalError("an early exit was accepted")
        } catch {}
        do {
            _ = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat >/dev/null"], timeout: 1)
            fatalError("a helper that never became ready was accepted")
        } catch CockpitChild.Failure.timeout {} catch { fatalError("wrong timeout result: \(error)") }
        print("Cockpit child lifecycle checks passed")
    }
}
