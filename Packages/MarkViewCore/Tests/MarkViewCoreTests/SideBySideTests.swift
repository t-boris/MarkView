import Foundation
import XCTest
@testable import MarkViewCore

/// Counts the runs going at once, from any thread.
private final class Gauge: @unchecked Sendable { // unchecked Sendable: every field is read and written under `lock`.
    private let lock = NSLock()
    private var running = 0
    private(set) var peak = 0
    private(set) var started: [Int] = []
    private(set) var cancelled: [Int] = []
    func begin(_ item: Int) { lock.lock(); running += 1; peak = max(peak, running); started.append(item); lock.unlock() }
    func end() { lock.lock(); running -= 1; lock.unlock() }
    func wasCancelled(_ item: Int) { lock.lock(); cancelled.append(item); lock.unlock() }
}

private struct Failed: Error {}

@MainActor
final class SideBySideTests: XCTestCase {
    /// Runs that end in another order than they started still come back in the order of the items, never more than `limit` at once,
    /// and `done` sees them as they end, on the caller's actor.
    func testOutputsKeepTheItemOrderAndAtMostLimitRunAtOnce() async throws {
        let gauge = Gauge()
        var finished: [Int] = []
        let outputs = try await SideBySide.map(Array(0..<9), limit: 3, work: { item in
            gauge.begin(item)
            defer { gauge.end() }
            // The first items wait the longest: without the ordering the later ones would come first.
            try await Task.sleep(nanoseconds: UInt64(9 - item) * 8_000_000)
            return item * 10
        }, done: { index, output in
            XCTAssertTrue(Thread.isMainThread, "done runs on the caller's actor")
            XCTAssertEqual(output, index * 10)
            finished.append(index)
        })
        XCTAssertEqual(outputs, Array(0..<9).map { $0 * 10 })
        XCTAssertEqual(gauge.peak, 3, "three run at once, never more")
        // Runs are launched in the order of the items; two launched together may begin in either order, but never one more
        // than a window apart.
        XCTAssertEqual(gauge.started.sorted(), Array(0..<9))
        for (position, item) in gauge.started.enumerated() { XCTAssertLessThan(abs(position - item), 3, "\(gauge.started)") }
        XCTAssertNotEqual(finished, Array(0..<9), "done follows the order the runs end")
        XCTAssertEqual(finished.sorted(), Array(0..<9))
    }

    /// A run that throws cancels the runs still going, starts no more, and its error reaches the caller.
    func testAThrownErrorCancelsTheOthersAndIsRethrown() async {
        let gauge = Gauge()
        do {
            _ = try await SideBySide.map(Array(0..<6), limit: 2, work: { item -> Int in
                gauge.begin(item)
                defer { gauge.end() }
                if item == 0 { try await Task.sleep(nanoseconds: 5_000_000); throw Failed() }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { gauge.wasCancelled(item); throw error }
                return item
            })
            XCTFail("the error is rethrown")
        } catch {
            XCTAssertTrue(error is Failed)
        }
        XCTAssertEqual(gauge.started.sorted(), [0, 1], "no run starts after the error")
        XCTAssertEqual(gauge.cancelled, [1])
    }

    /// Cancelling the caller cancels every run and ends the call with a cancellation.
    func testCancellingTheCallerStopsEveryRun() async {
        let gauge = Gauge()
        let call = Task { @MainActor in
            try await SideBySide.map(Array(0..<4), limit: 4, work: { item -> Int in
                gauge.begin(item)
                defer { gauge.end() }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { gauge.wasCancelled(item); throw error }
                return item
            })
        }
        while gauge.started.count < 4 { await Task.yield() }
        call.cancel()
        let result = await call.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(gauge.cancelled.sorted(), [0, 1, 2, 3])
    }

    /// Runs that end normally when cancelled still reach `done`, the items not started yet never start, and the call throws.
    func testACancelledCallerStartsNoMoreRuns() async {
        let gauge = Gauge()
        var seen: [Int] = []
        let call = Task { @MainActor in
            try await SideBySide.map(Array(0..<5), limit: 2, work: { item -> Int in
                gauge.begin(item)
                defer { gauge.end() }
                // A run that turns its cancellation into an output, as a section kept in its source language does.
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { gauge.wasCancelled(item); return -1 }
                return item
            }, done: { index, _ in seen.append(index) })
        }
        while gauge.started.count < 2 { await Task.yield() }
        call.cancel()
        let result = await call.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(gauge.started.sorted(), [0, 1], "no run starts after the cancellation")
        XCTAssertEqual(seen.sorted(), [0, 1], "the runs that were going still report")
    }

    func testNoItemsRunNothing() async throws {
        let outputs = try await SideBySide.map([Int](), limit: 3, work: { $0 })
        XCTAssertTrue(outputs.isEmpty)
    }
}
