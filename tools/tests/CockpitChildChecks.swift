import Foundation
import Darwin

@main struct Checks {
    static func main() async throws {
        let exited = CockpitExitSignal()
        let (child, line) = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"ready\":true}\\n'; cat >/dev/null"], timeout: 3,
                                                          onExit: { Task { await exited.finish() } })
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Bool], json["ready"] == true else { fatalError("readiness was not read") }
        child.stop()
        await exited.wait()
        for _ in 0..<100 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        guard AgentProcesses.count == 0 else { fatalError("helper did not stop on EOF") }
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { fatalError("test PTY could not be opened") }
        defer { close(master); close(slave) }
        let descriptor = dup(master)
        guard descriptor >= 0 else { fatalError("test PTY could not be duplicated") }
        let (ptyChild, _) = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "if [ -t 2 ]; then printf '{\"ready\":true}\\n'; cat >/dev/null; else exit 1; fi"], timeout: 3, ptyDescriptor: descriptor)
        ptyChild.stop()
        await ptyChild.waitForExit()
        let removed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: removed)
        do {
            _ = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/not-a-cockpit-helper"), arguments: [], onExit: {
                try? FileManager.default.removeItem(at: removed)
            })
            fatalError("a missing helper was accepted")
        } catch {}
        guard !FileManager.default.fileExists(atPath: removed.path) else { fatalError("failed helper did not clean up") }
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
