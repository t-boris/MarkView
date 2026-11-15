import Darwin
import Foundation
import XCTest
@testable import MarkViewCore

/// A child leads a process group of its own, so a timeout or a cancellation reaches its grandchildren (`FU-22`).
/// Each test starts a shell that leaves a `sleep` behind and checks that grandchild with `kill(pid, 0)`.
final class SubprocessProcessGroupTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mvgroup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Whatever a test left behind must not outlive it.
        if let files = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil) {
            for file in files { if let pid = Self.pid(in: file) { kill(pid, SIGKILL) } }
        }
        try? FileManager.default.removeItem(at: scratch)
    }

    private static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Waits for the shell to write the grandchild's pid.
    private func grandchildPid(_ file: URL, within seconds: TimeInterval = 3) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let pid = Self.pid(in: file) { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The shell never wrote the grandchild's pid")
        throw CancellationError()
    }

    /// True once `pid` no longer exists (a zombie that nobody reaped yet still answers `kill(pid, 0)`, so give init a moment).
    private func gone(_ pid: pid_t, within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return kill(pid, 0) != 0
    }

    /// `sleep 60` in the background, its pid in `file`, then the shell waits for it.
    private func spec(_ script: String, file: URL, timeout: TimeInterval, grace: TimeInterval = 0.5) -> SubprocessSpec {
        SubprocessSpec(executable: "/bin/sh", arguments: ["-c", script, "sh", file.path], timeout: timeout, terminationGrace: grace)
    }

    func testTimeoutEndsTheGrandchildToo() async throws {
        let file = scratch.appendingPathComponent("timeout.pid")
        let result = await Subprocess.run(spec("sleep 60 & echo $! > \"$1\"; wait", file: file, timeout: 0.5))
        XCTAssertTrue(result.timedOut)
        let pid = try await grandchildPid(file)
        let ended = await gone(pid, within: 3)
        XCTAssertTrue(ended, "The grandchild of a timed-out command is still running")
    }

    func testCancellationEndsTheGrandchildToo() async throws {
        let file = scratch.appendingPathComponent("cancel.pid")
        let task = Task { await Subprocess.run(spec("sleep 60 & echo $! > \"$1\"; wait", file: file, timeout: 60)) }
        let pid = try await grandchildPid(file)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.succeeded)
        let ended = await gone(pid, within: 3)
        XCTAssertTrue(ended, "The grandchild of a cancelled command is still running")
    }

    func testDescendantsThatIgnoreSIGTERMAreKilledAfterTheGrace() async throws {
        let file = scratch.appendingPathComponent("ignore.pid")
        // The shell and the sleep it starts both ignore SIGTERM (an ignored signal stays ignored through exec).
        let result = await Subprocess.run(spec("trap '' TERM; sleep 60 & echo $! > \"$1\"; wait", file: file, timeout: 0.3, grace: 0.3))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(result.durationMs, 3000)
        let pid = try await grandchildPid(file)
        let ended = await gone(pid, within: 3)
        XCTAssertTrue(ended, "A descendant that ignores SIGTERM survived the SIGKILL after the grace period")
    }

    func testDescendantThatIgnoresSIGTERMIsKilledEvenWhenTheLeaderEndsAtOnce() async throws {
        // The shell ends at SIGTERM, its background child ignores it: only the SIGKILL after the grace period reaches that child.
        let file = scratch.appendingPathComponent("survivor.pid")
        let result = await Subprocess.run(spec("(trap '' TERM; exec sleep 60) & echo $! > \"$1\"; wait", file: file, timeout: 0.3, grace: 0.3))
        XCTAssertTrue(result.timedOut)
        let pid = try await grandchildPid(file)
        let ended = await gone(pid, within: 3)
        XCTAssertTrue(ended, "A descendant that ignores SIGTERM survived because the leader had already ended")
    }

    func testNormalExitLeavesBackgroundDescendantsAlone() async throws {
        // A command that ends by itself keeps what it started (an ssh control master, a daemon): only a timeout or a cancellation ends the group.
        let file = scratch.appendingPathComponent("daemon.pid")
        let result = await Subprocess.run(spec("sleep 60 >/dev/null 2>&1 & echo $! > \"$1\"", file: file, timeout: 5))
        XCTAssertTrue(result.succeeded)
        let pid = try await grandchildPid(file)
        try await Task.sleep(nanoseconds: 700_000_000)   // longer than the grace period
        XCTAssertEqual(kill(pid, 0), 0, "A command that ended normally must not take its background process down")
    }

    func testChildLeadsItsOwnGroupNeverTheApps() async {
        let result = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", "echo $$; ps -o pgid= -p $$"], timeout: 5))
        let numbers = result.stdout.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(numbers.count, 2)
        XCTAssertEqual(numbers.first, numbers.last, "The child must be the leader of its own process group")
        XCTAssertNotEqual(numbers.last, getpgrp(), "The child shares the group of the app")
    }

    func testTheGroupOfTheAppIsNeverASignalTarget() {
        XCTAssertNil(SubprocessChild.signalTarget(forGroupOf: getpgrp()))
        XCTAssertNil(SubprocessChild.signalTarget(forGroupOf: 1))
        XCTAssertNil(SubprocessChild.signalTarget(forGroupOf: 0))
        XCTAssertNil(SubprocessChild.signalTarget(forGroupOf: -3))
        XCTAssertNil(SubprocessChild.signalTarget(forGroupOf: 4321, ownGroup: 4321))
        XCTAssertEqual(SubprocessChild.signalTarget(forGroupOf: 4321, ownGroup: 99), -4321)
    }

    func testLargeOutputIsDrainedWhileTheChildRuns() async {
        // Far more than a pipe holds: the child would stop at 64 KB if nobody read.
        let result = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' x"], timeout: 20))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.utf8.count, 3_000_000)
        XCTAssertFalse(result.truncated)
    }

    func testInputIsWrittenAndClosed() async {
        let result = await Subprocess.run(SubprocessSpec(
            executable: "/bin/cat", stdin: Data("typed into the child".utf8), timeout: 5))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "typed into the child")
    }

    func testEnvironmentOverridesMergeIntoTheInheritedEnvironment() async {
        let result = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", "printf '%s|%s' \"$HOME\" \"$MV_GROUP_TEST\""],
            environment: ["MV_GROUP_TEST": "set"], timeout: 5))
        let parts = result.stdout.components(separatedBy: "|")
        XCTAssertEqual(parts.last, "set")
        XCTAssertEqual(parts.first, ProcessInfo.processInfo.environment["HOME"], "The inherited environment is lost")
    }

    func testRemovedEnvironmentIsNotInherited() async {
        setenv("MV_GROUP_INHERITED", "secret", 1)
        defer { unsetenv("MV_GROUP_INHERITED") }
        let script = "printf '%s|%s' \"${MV_GROUP_INHERITED-unset}\" \"${MV_GROUP_KEPT-unset}\""
        let kept = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", script], environment: ["MV_GROUP_KEPT": "yes"], timeout: 5))
        XCTAssertEqual(kept.stdout, "secret|yes")
        let removed = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", script], environment: ["MV_GROUP_KEPT": "yes"],
            removedEnvironment: ["MV_GROUP_INHERITED"], timeout: 5))
        XCTAssertEqual(removed.stdout, "unset|yes")
    }

    func testNoLimitWhenTheTimeoutIsNotPositive() async {
        for timeout in [0.0, -1.0] {
            let result = await Subprocess.run(SubprocessSpec(
                executable: "/bin/sh", arguments: ["-c", "sleep 0.3; echo finished"], timeout: timeout))
            XCTAssertTrue(result.succeeded, "timeout \(timeout)")
            XCTAssertFalse(result.timedOut, "timeout \(timeout)")
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "finished")
        }
    }

    func testCancelledBeforeItStartsNeverStartsTheChild() async {
        let marker = scratch.appendingPathComponent("started")
        let task = Task { () -> SubprocessResult in
            // A task that is already cancelled when it reaches `run`.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return await Subprocess.run(SubprocessSpec(
                executable: "/usr/bin/touch", arguments: [marker.path], timeout: 5))
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
