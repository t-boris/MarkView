import Foundation
import os
import XCTest
@testable import MarkViewCore

/// A clock the test moves by hand: a sleep suspends until `advance` passes its due time, and a cancelled sleep ends at once.
private final class ManualClock: Sendable {
    private struct Waiter {
        let id: Int
        let due: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var time = Date(timeIntervalSince1970: 1_000)
        var nextID = 0
        var waiters: [Waiter] = []
        var cancelled: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Date { state.withLock { $0.time } }
    /// How many sleeps are pending: a scheduler that is paused or has no job holds none.
    var sleepers: Int { state.withLock { $0.waiters.count } }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = state.withLock { state -> Int in state.nextID += 1; return state.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelledAlready = state.withLock { state -> Bool in
                    if state.cancelled.contains(id) { return true }
                    state.waiters.append(Waiter(id: id, due: state.time.addingTimeInterval(seconds), continuation: continuation))
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { state.cancelled.insert(id); return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(_ seconds: TimeInterval) {
        let due = state.withLock { state -> [Waiter] in
            state.time = state.time.addingTimeInterval(seconds)
            let ready = state.waiters.filter { $0.due <= state.time }
            state.waiters.removeAll { $0.due <= state.time }
            return ready.sorted { $0.due < $1.due }
        }
        for waiter in due { waiter.continuation.resume() }
    }
}

@MainActor
private final class Counter {
    var runs = 0
    var cancelledRuns = 0
}

/// `AR-19`: one scheduler for every poll. It runs a job only while the app is active and the window is on screen, a paused scheduler holds
/// no timer at all, and the owner ends every job when it closes. Time is a manual clock, so nothing here sleeps.
@MainActor
final class PollingSchedulerTests: XCTestCase {
    private func make(clock: ManualClock, appActive: Bool = true) -> PollingScheduler {
        PollingScheduler(isAppActive: appActive, sleep: { try await clock.sleep($0) }, now: { clock.now })
    }

    /// Lets the main actor run what a step released: a task switch is a yield, so this needs no time.
    private func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
    }

    private func ticked(_ counter: Counter, _ expected: Int) async {
        await settle { counter.runs >= expected }
        await settle()   // and let a run that should not have happened show
    }

    func testAJobRunsEachIntervalAndNotBefore() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        scheduler.every(10, key: "poll") { counter.runs += 1 }
        await settle { clock.sleepers == 1 }
        clock.advance(9)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 0, "nothing runs before the interval has passed")
        clock.advance(1)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 1, "the job runs when the interval has passed")
        await settle { clock.sleepers == 1 }
        clock.advance(10)
        await ticked(counter, 2)
        XCTAssertEqual(counter.runs, 2, "and again each interval")
        scheduler.stopAll()
    }

    func testAnImmediateJobRunsAtOnce() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        scheduler.every(10, key: "poll", immediately: true) { counter.runs += 1 }
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 1, "the first run does not wait for the interval")
        scheduler.stopAll()
    }

    func testAPausedSchedulerDoesNotTickAndHoldsNoTimer() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        scheduler.every(10, key: "poll") { counter.runs += 1 }
        await settle { clock.sleepers == 1 }
        scheduler.setAppActive(false)
        await settle { clock.sleepers == 0 }
        XCTAssertFalse(scheduler.isVisible)
        XCTAssertEqual(clock.sleepers, 0, "a paused scheduler holds no pending sleep: nothing wakes the process")
        XCTAssertEqual(scheduler.runningCount, 0)
        clock.advance(1_000)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 0, "a paused scheduler does not tick, however much time passes")
        scheduler.every(5, key: "later") { counter.runs += 1 }
        clock.advance(1_000)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 0, "a job scheduled while paused does not tick either")
        XCTAssertEqual(clock.sleepers, 0)
        scheduler.stopAll()
    }

    func testAHiddenWindowPausesAndBothMustBeVisible() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        scheduler.every(10, key: "poll") { counter.runs += 1 }
        await settle { clock.sleepers == 1 }
        scheduler.setWindowVisible(false)
        await settle { clock.sleepers == 0 }
        XCTAssertEqual(clock.sleepers, 0, "an occluded window pauses the job")
        scheduler.setAppActive(false)
        scheduler.setWindowVisible(true)
        XCTAssertFalse(scheduler.isVisible, "a visible window of an inactive app is still paused")
        await settle()
        XCTAssertEqual(clock.sleepers, 0)
        scheduler.setAppActive(true)
        await settle { clock.sleepers == 1 }
        XCTAssertTrue(scheduler.isVisible)
        XCTAssertEqual(clock.sleepers, 1, "both back: the job is scheduled again")
        scheduler.stopAll()
    }

    func testAJobThatIsDueWhenVisibilityReturnsRunsAtOnceAndOthersWaitForTheRest() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        let slow = Counter()
        scheduler.every(10, key: "short") { counter.runs += 1 }
        scheduler.every(100, key: "long") { slow.runs += 1 }
        await settle { clock.sleepers == 2 }
        scheduler.setAppActive(false)
        await settle { clock.sleepers == 0 }
        clock.advance(30)
        scheduler.setAppActive(true)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 1, "the job whose interval passed while hidden runs as soon as it is visible, once")
        XCTAssertEqual(slow.runs, 0, "a job with time left waits for the rest of it")
        await settle { clock.sleepers == 2 }
        clock.advance(70)
        await ticked(slow, 1)
        XCTAssertEqual(slow.runs, 1, "and runs when that is over (100 s since its last run)")
        scheduler.stopAll()
    }

    func testARunCutShortByPausingRunsAgainWhenVisible() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        scheduler.every(10, key: "poll") {
            counter.runs += 1
            do { try await clock.sleep(1_000) } catch { counter.cancelledRuns += 1 }
        }
        await settle { clock.sleepers == 1 }
        clock.advance(10)
        await settle { counter.runs == 1 }
        scheduler.setAppActive(false)
        await settle { counter.cancelledRuns == 1 }
        XCTAssertEqual(counter.cancelledRuns, 1, "a run in progress is cancelled when the app resigns")
        XCTAssertEqual(clock.sleepers, 0)
        scheduler.setAppActive(true)
        await settle { counter.runs == 2 }
        XCTAssertEqual(counter.runs, 2, "a run that was cut short counts as not run: it starts again at once")
        scheduler.stopAll()
    }

    func testAnInboxJobKeepsItsCadenceWhileTheAppIsInTheBackground() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let inbox = Counter()
        let poll = Counter()
        scheduler.every(1, key: "inbox", pausesWhenHidden: false) { inbox.runs += 1 }
        scheduler.every(1, key: "poll") { poll.runs += 1 }
        await settle { clock.sleepers == 2 }
        scheduler.setAppActive(false)
        await settle { clock.sleepers == 1 }
        XCTAssertEqual(clock.sleepers, 1, "only the job that pauses stops sleeping")
        clock.advance(1)
        await ticked(inbox, 1)
        XCTAssertEqual(inbox.runs, 1, "a job that listens for another process still runs in the background")
        XCTAssertEqual(poll.runs, 0, "and an ordinary poll does not")
        scheduler.stopAll()
    }

    func testAJobCanChangeItsCadenceBetweenRuns() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        var busy = false
        scheduler.every(key: "runs", interval: { busy ? 2 : 10 }) { counter.runs += 1; busy = true }
        await settle { clock.sleepers == 1 }
        clock.advance(10)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 1, "the first wait is the idle interval")
        await settle { clock.sleepers == 1 }
        clock.advance(2)
        await ticked(counter, 2)
        XCTAssertEqual(counter.runs, 2, "the next wait follows what the job reports now")
        scheduler.stopAll()
    }

    func testSchedulingAKeyAgainReplacesAndStopEndsTheJob() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let first = Counter()
        let second = Counter()
        scheduler.every(10, key: "poll") { first.runs += 1 }
        scheduler.every(20, key: "poll") { second.runs += 1 }
        await settle { clock.sleepers == 1 }
        XCTAssertEqual(scheduler.keys, ["poll"], "one job per key")
        XCTAssertEqual(clock.sleepers, 1, "the replaced job's sleep is gone")
        clock.advance(10)
        await ticked(first, 1)
        XCTAssertEqual(first.runs + second.runs, 0, "the old interval no longer applies")
        clock.advance(10)
        await ticked(second, 1)
        XCTAssertEqual(first.runs, 0, "the replaced job never runs")
        XCTAssertEqual(second.runs, 1)
        scheduler.stop(key: "poll")
        await settle { clock.sleepers == 0 }
        XCTAssertEqual(clock.sleepers, 0)
        XCTAssertTrue(scheduler.keys.isEmpty)
        clock.advance(100)
        await ticked(second, 2)
        XCTAssertEqual(second.runs, 1, "a stopped job does not run again")
    }

    func testClosingTheOwnerEndsEveryJobAndTheyDoNotComeBack() async {
        let clock = ManualClock()
        let scheduler = make(clock: clock)
        let counter = Counter()
        scheduler.every(10, key: "a") { counter.runs += 1 }
        scheduler.every(15, key: "b") { counter.runs += 1 }
        await settle { clock.sleepers == 2 }
        scheduler.stopAll()
        await settle { clock.sleepers == 0 }
        XCTAssertEqual(clock.sleepers, 0, "every sleep ends with the owner")
        clock.advance(1_000)
        await ticked(counter, 1)
        XCTAssertEqual(counter.runs, 0, "nothing runs after close")
        scheduler.setAppActive(false)
        scheduler.setAppActive(true)
        await settle()
        XCTAssertEqual(clock.sleepers, 0, "and visibility coming back does not bring a closed owner's jobs back")
    }
}
