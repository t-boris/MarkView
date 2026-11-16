import Foundation
import XCTest
@testable import MarkViewCore

@MainActor
final class OrderedWorkTests: XCTestCase {
    /// Pieces that suspend for different times still run in the order they were asked for, and never two at once.
    func testPiecesRunInOrderAndNeverOverlap() async {
        let work = OrderedWork()
        var finished: [Int] = []
        var running = 0, overlapped = false
        for index in 0..<20 {
            work.enqueue {
                running += 1
                if running > 1 { overlapped = true }
                // The first pieces wait the longest: without the queue the later ones would end first.
                try? await Task.sleep(nanoseconds: UInt64(20 - index) * 1_000_000)
                finished.append(index)
                running -= 1
            }
        }
        await work.drain()
        XCTAssertEqual(finished, Array(0..<20))
        XCTAssertFalse(overlapped)
    }

    /// `drain()` returns only after what was asked for before it, and a piece asked for from inside another piece runs after those.
    func testDrainWaitsForEverythingAskedForBeforeIt() async {
        let work = OrderedWork()
        var log: [String] = []
        work.enqueue {
            try? await Task.sleep(nanoseconds: 30_000_000)
            log.append("first")
            work.enqueue { log.append("nested") }
        }
        work.enqueue { log.append("second") }
        await work.drain()
        XCTAssertEqual(Array(log.prefix(2)), ["first", "second"])
        await work.drain()
        XCTAssertEqual(log, ["first", "second", "nested"])
    }

    /// A queue with nothing asked for drains at once, and a piece asked for after the queue went idle still runs.
    func testIdleQueueDrainsAndRestarts() async {
        let work = OrderedWork()
        await work.drain()
        var ran = 0
        work.enqueue { ran += 1 }
        await work.drain()
        work.enqueue { ran += 1 }
        await work.drain()
        XCTAssertEqual(ran, 2)
    }
}
