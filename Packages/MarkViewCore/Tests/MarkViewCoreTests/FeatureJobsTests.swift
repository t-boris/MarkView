import Foundation
import XCTest
@testable import MarkViewCore

@MainActor
final class FeatureJobsTests: XCTestCase {
    func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }
    @MainActor
    func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// What the jobs wrote, and in what order they started and ended.
    @MainActor
    final class Log {
        var started: [String] = []
        var written: [String] = []
        var cancelled: [String] = []

        /// Work that takes `nanoseconds` and writes `label` only when it was not cancelled meanwhile.
        func work(_ label: String, nanoseconds: UInt64) -> @MainActor () async -> Void {
            return { [self] in
                started.append(label)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled {
                    cancelled.append(label)
                    return
                }
                written.append(label)
            }
        }
    }

    @MainActor
    func testStart() async {
        print("-- start and finish")
        let jobs = FeatureJobs()
        let log = Log()
        check(!jobs.isRunning("explore:a"), "nothing runs before a start")
        check(jobs.start("explore:a", log.work("a", nanoseconds: 50_000_000)), "a start returns at once and says it started")
        check(jobs.isRunning("explore:a"), "the job runs under its key")
        check(await waitUntil { log.written == ["a"] }, "the work finishes and writes")
        check(await waitUntil { !jobs.isRunning("explore:a") }, "a finished job leaves its key free")
        let again = jobs.start("explore:a", log.work("a2", nanoseconds: 10_000_000))
        let wrote = await waitUntil { log.written == ["a", "a2"] }
        check(again && wrote, "the same key starts again once it is free")
    }

    @MainActor
    func testRestart() async {
        print("-- a second start of a key that runs")
        let jobs = FeatureJobs()
        let log = Log()
        check(jobs.start("review:a", log.work("first", nanoseconds: 300_000_000)), "the first start runs")
        check(!jobs.start("review:a", log.work("second", nanoseconds: 10_000_000)), "a second start of the same key is refused")
        check(jobs.start("review:b", log.work("other", nanoseconds: 10_000_000)), "another key runs beside it")
        check(await waitUntil { log.written.contains("other") && log.written.contains("first") }, "both finish")
        check(log.started == ["first", "other"] && !log.written.contains("second"), "the refused work never ran")
    }

    @MainActor
    func testClosing() async {
        print("-- the folder switches or the window closes")
        let jobs = FeatureJobs()
        let log = Log()
        jobs.start("explore:a", log.work("a", nanoseconds: 2_000_000_000))
        jobs.start("chat:a", log.work("b", nanoseconds: 2_000_000_000))
        await Task.yield()
        check(jobs.isRunning("explore:a") && jobs.isRunning("chat:a"), "two jobs run")
        jobs.cancelAll()
        check(await waitUntil { log.cancelled.sorted() == ["a", "b"] }, "cancelAll ends every job")
        check(log.written.isEmpty, "and no job writes after it")
        check(await waitUntil { !jobs.isRunning("explore:a") && !jobs.isRunning("chat:a") }, "the keys are free again")
        let next = jobs.start("explore:a", log.work("c", nanoseconds: 10_000_000))
        let wrote = await waitUntil { log.written == ["c"] }
        check(next && wrote, "a job of the next folder starts as usual")
    }

}
