import Foundation
import XCTest
@testable import MarkViewCore

final class AgentProcessesTests: XCTestCase {
    func testRegistryStopsItsChildrenAndForgetsFinishedOnes() async throws {
        func start(_ script: String) throws -> SubprocessChild {
            let child = try Subprocess.start(
                SubprocessSpec(executable: "/bin/sh", arguments: ["-c", script], timeout: 0),
                onExit: { child, _ in AgentProcesses.remove(child) })
            AgentProcesses.add(child)
            if !child.isRunning { AgentProcesses.remove(child) }
            return child
        }

        let polite = try start("sleep 60")
        let stubborn = try start("trap '' TERM; while true; do sleep 1; done")
        defer {
            polite.kill()
            stubborn.kill()
            AgentProcesses.remove(polite)
            AgentProcesses.remove(stubborn)
        }
        let finished = try start("exit 0")
        await finished.waitForExit()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(AgentProcesses.count, 2, "A finished process should be forgotten.")
        XCTAssertTrue(polite.isRunning && stubborn.isRunning)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            AgentProcesses.add(polite)
            AgentProcesses.add(stubborn)
        }
        XCTAssertEqual(AgentProcesses.count, 2, "Concurrent registration should retain one entry per process.")

        let began = Date()
        AgentProcesses.terminateAll(grace: 0.5)
        let elapsed = Date().timeIntervalSince(began)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(polite.isRunning)
        XCTAssertFalse(stubborn.isRunning)
        XCTAssertLessThan(elapsed, 2, "Quitting should not wait on an uncooperative process.")
    }
}
