import Darwin
import Foundation
import XCTest
@testable import MarkViewCore

/// `Subprocess.start`: the streaming child of the CLI assistants, the Cockpit helpers, the remote commands and the indexer (`AR-25`).
/// Every check runs a real child and looks at what a caller sees: the order of output and exit, the routing of the streams,
/// the input pipe and how the child ended.
final class SubprocessStartTests: XCTestCase {
    /// What the callbacks of one child delivered, in order. `events` holds "out", "err" and "exit" markers.
    // unchecked Sendable: `lock` guards every field.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var marks: [String] = []
        private var ended: SubprocessExit?
        func stdout(_ data: Data) { lock.lock(); out.append(data); marks.append("out"); lock.unlock() }
        func stderr(_ data: Data) { lock.lock(); err.append(data); marks.append("err"); lock.unlock() }
        func exit(_ result: SubprocessExit) { lock.lock(); ended = result; marks.append("exit"); lock.unlock() }
        var stdoutText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var stderrText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return marks }
        var result: SubprocessExit? { lock.lock(); defer { lock.unlock() }; return ended }
    }

    private func start(_ spec: SubprocessSpec, _ recorder: Recorder) throws -> SubprocessChild {
        try Subprocess.start(spec, onStdout: { recorder.stdout($0) }, onStderr: { recorder.stderr($0) }, onExit: { _, exit in recorder.exit(exit) })
    }

    private func sh(_ script: String, _ configure: (inout SubprocessSpec) -> Void = { _ in }) -> SubprocessSpec {
        var spec = SubprocessSpec(executable: "/bin/sh", arguments: ["-c", script], timeout: 10)
        configure(&spec)
        return spec
    }

    func testOutputArrivesBeforeTheExitAndStreamsAreSeparate() async throws {
        let recorder = Recorder()
        let child = try start(sh("echo first; echo problem >&2; echo second; exit 3"), recorder)
        await child.waitForExit()
        XCTAssertEqual(recorder.stdoutText, "first\nsecond\n")
        XCTAssertEqual(recorder.stderrText, "problem\n")
        XCTAssertEqual(recorder.events.last, "exit", "The exit must follow the last output")
        XCTAssertEqual(recorder.events.filter { $0 == "exit" }.count, 1)
        XCTAssertEqual(recorder.result?.status, 3)
        XCTAssertEqual(recorder.result?.signaled, false)
        XCTAssertEqual(child.exit, recorder.result)
        XCTAssertFalse(child.isRunning)
    }

    func testMergedStderrKeepsTheInterleavingOfOneStream() async throws {
        let recorder = Recorder()
        let child = try start(sh("echo one; echo two >&2; echo three", { $0.stderrRouting = .mergedWithStdout }), recorder)
        await child.waitForExit()
        XCTAssertEqual(recorder.stdoutText, "one\ntwo\nthree\n")
        XCTAssertEqual(recorder.stderrText, "")
    }

    func testDiscardedStreamsAreNeverDelivered() async throws {
        let recorder = Recorder()
        let child = try start(sh("echo visible; echo hidden >&2", { $0.stderrRouting = .discard }), recorder)
        await child.waitForExit()
        XCTAssertEqual(recorder.stdoutText, "visible\n")
        XCTAssertEqual(recorder.stderrText, "")
    }

    func testDescriptorRoutingWritesStraightIntoTheCallersFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mvstart-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        let recorder = Recorder()
        let child = try start(sh("printf 'into the file'", { $0.stdoutRouting = .descriptor(handle.fileDescriptor) }), recorder)
        await child.waitForExit()
        try handle.close()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "into the file")
        XCTAssertEqual(recorder.stdoutText, "")
    }

    func testInputPipeStaysOpenUntilTheCallerClosesIt() async throws {
        let recorder = Recorder()
        let child = try start(sh("cat", { $0.keepsInputOpen = true }), recorder)
        XCTAssertNotNil(child.inputFileDescriptor)
        try child.writeInput(Data("request one\n".utf8))
        try child.writeInput(Data("request two\n".utf8))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(child.isRunning, "A child that is waiting for input must keep running")
        XCTAssertEqual(recorder.stdoutText, "request one\nrequest two\n")
        child.closeInput()
        XCTAssertNil(child.inputFileDescriptor)
        await child.waitForExit()
        XCTAssertEqual(recorder.result?.status, 0)
        XCTAssertThrowsError(try child.writeInput(Data("late".utf8)), "A closed input cannot be written")
    }

    func testWritingToAChildThatEndedFailsWithoutKillingTheApp() async throws {
        let recorder = Recorder()
        let child = try start(sh("exit 0", { $0.keepsInputOpen = true }), recorder)
        await child.waitForExit()
        // The broken pipe is an error for the caller, never a SIGPIPE for the process.
        XCTAssertThrowsError(try child.writeInput(Data(repeating: 0x41, count: 1_000_000)))
    }

    func testStdinDataIsDeliveredAndClosed() async throws {
        let recorder = Recorder()
        let child = try start(SubprocessSpec(executable: "/bin/cat", stdin: Data("the prompt".utf8), timeout: 10), recorder)
        await child.waitForExit()
        XCTAssertEqual(recorder.stdoutText, "the prompt")
        XCTAssertEqual(recorder.result?.status, 0)
    }

    func testChildEndedBySignalReportsTheSignal() async throws {
        let recorder = Recorder()
        let child = try start(sh("kill -KILL $$"), recorder)
        await child.waitForExit()
        XCTAssertEqual(recorder.result?.signaled, true)
        XCTAssertEqual(recorder.result?.status, SIGKILL)
    }

    func testTimeoutEndsTheChildAndSaysSo() async throws {
        let recorder = Recorder()
        let child = try start(sh("sleep 30", { $0.timeout = 0.3; $0.terminationGrace = 0.3 }), recorder)
        await child.waitForExit()
        XCTAssertEqual(recorder.result?.timedOut, true)
        XCTAssertEqual(recorder.result?.signaled, true)
    }

    func testTerminateEndsAChildWithoutATimeout() async throws {
        let recorder = Recorder()
        let child = try start(sh("sleep 30", { $0.timeout = 0 }), recorder)
        XCTAssertTrue(child.isRunning)
        child.terminate(grace: 0.3)
        child.terminate(grace: 0.3)   // asking again is harmless
        await child.waitForExit()
        XCTAssertEqual(recorder.result?.timedOut, false)
        XCTAssertEqual(recorder.result?.status, SIGTERM)
    }

    func testChildWorksInTheGivenFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mvstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let child = try start(sh("pwd -P", { $0.cwd = folder }), recorder)
        await child.waitForExit()
        let real = folder.path.withCString { realpath($0, nil) }.map { String(cString: $0) }
        XCTAssertEqual(recorder.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), real)
    }

    func testAMissingProgramIsALaunchErrorNotAnExit() {
        XCTAssertThrowsError(try Subprocess.start(
            SubprocessSpec(executable: "/no/such/program", timeout: 1), onExit: { _, _ in XCTFail("nothing ran") })) { error in
            XCTAssertTrue(error is SubprocessLaunchError)
        }
    }

    func testRunEndsAChildThatPassesTheOutputCapWhenAsked() async {
        let result = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", "yes | head -c 50000000"], timeout: 20,
            maxOutputBytes: 8192, terminateOnOverflow: true))
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.durationMs, 10_000)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 8192)
    }

    func testRunBlockingReturnsTheSameResultAsRun() {
        let result = Subprocess.runBlocking(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", "echo kept; echo dropped >&2; exit 2"], timeout: 10,
            stderrRouting: .discard))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(result.stdout, "kept\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(result.timedOut)
    }

    func testRunBlockingOnATimeoutKillsTheChildAndReturns() {
        let result = Subprocess.runBlocking(SubprocessSpec(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 0.3, terminationGrace: 0.3))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(result.durationMs, 5000)
    }
}
