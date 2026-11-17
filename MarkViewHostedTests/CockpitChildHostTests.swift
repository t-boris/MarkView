import Foundation
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

extension EditorHostTests {
    func testCockpitChildLifecycle() async throws {
        let initialProcesses = AgentProcesses.count
        let exited = CockpitExitSignal()
        let (child, line) = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"ready\":true}\\n'; cat >/dev/null"], timeout: 3,
                                                          onExit: { Task { await exited.finish() } })
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Bool], json["ready"] == true else { XCTFail("readiness was not read"); return }
        defer { child.stop() }
        child.stop()
        await exited.wait()
        for _ in 0..<100 where AgentProcesses.count != initialProcesses { try await Task.sleep(nanoseconds: 20_000_000) }
        guard AgentProcesses.count == initialProcesses else { XCTFail("helper did not stop on EOF"); return }
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { XCTFail("test PTY could not be opened"); return }
        defer { close(master); close(slave) }
        let descriptor = dup(master)
        guard descriptor >= 0 else { XCTFail("test PTY could not be duplicated"); return }
        let (ptyChild, _) = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "if [ -t 2 ]; then printf '{\"ready\":true}\\n'; cat >/dev/null; else exit 1; fi"], timeout: 3, ptyDescriptor: descriptor)
        ptyChild.stop()
        await ptyChild.waitForExit()
        let removed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: removed) }
        try Data().write(to: removed)
        do {
            _ = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/not-a-cockpit-helper"), arguments: [], onExit: {
                try? FileManager.default.removeItem(at: removed)
            })
            XCTFail("a missing helper was accepted")
        } catch {}
        guard !FileManager.default.fileExists(atPath: removed.path) else { XCTFail("failed helper did not clean up"); return }
        do {
            _ = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 1"], timeout: 3)
            XCTFail("an early exit was accepted")
        } catch {}
        do {
            _ = try await CockpitChild.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat >/dev/null"], timeout: 1)
            XCTFail("a helper that never became ready was accepted")
        } catch CockpitChild.Failure.timeout {} catch { XCTFail("wrong timeout result: \(error)") }
    }
}
