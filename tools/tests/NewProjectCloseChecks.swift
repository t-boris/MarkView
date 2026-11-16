import Foundation

// Start a Project from Scratch (AR-19): what closing the sheet does to the work it started. The objects are the shipping NewProjectFlow,
// FeatureStore, FeatureAssistant, FeatureJobs and TaskBag; no assistant is asked and nothing is saved (the step the flow starts for a
// draft that does not exist ends at once). "Slow" work is a sleep that ends when the job is cancelled; what it records after waking
// tells whether a cancelled job still writes and whether the store it reads is still there.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// What the jobs wrote, and which ones were cut off.
@MainActor
final class Log {
    var written: [String] = []
    var cancelled: [String] = []
    /// The folder the store had when a job woke up and read it through its assistant (nil: a folder is not open, which a new draft never has).
    var woke: [String] = []

    func work(_ label: String, nanoseconds: UInt64) -> @MainActor (FeatureAssistant) async -> Void {
        return { [self] assistant in
            try? await Task.sleep(nanoseconds: nanoseconds)
            // The way every AI step reads the store once more after its call.
            _ = assistant.store.root
            woke.append(label)
            if Task.isCancelled {
                cancelled.append(label)
                return
            }
            written.append(label)
        }
    }
}

@MainActor
func startAndRestart() async {
    print("-- a job started through the assistant")
    let flow = NewProjectFlow()
    let log = Log()
    check(flow.assistant.start("explore:a", log.work("a", nanoseconds: 300_000_000)), "the job starts")
    check(flow.store.jobs.isRunning("explore:a"), "it runs under its key in the store's jobs")
    check(!flow.assistant.start("explore:a", log.work("again", nanoseconds: 10_000_000)), "a second start of the key is refused")
    check(flow.assistant.error?.contains("already running") == true, "and says the step is already running")
    check(flow.assistant.start("decide:a", log.work("other", nanoseconds: 10_000_000)), "another key runs beside it")
    check(await waitUntil { log.written.contains("a") && log.written.contains("other") }, "both finish and write")
    check(!log.written.contains("again"), "the refused work never ran")
    check(await waitUntil { !flow.store.jobs.isRunning("explore:a") }, "a finished job leaves its key free")
    check(flow.assistant.start("explore:a", log.work("a2", nanoseconds: 10_000_000)), "the same key starts again")
    check(await waitUntil { log.written.contains("a2") }, "and writes")
}

@MainActor
func closeEndsTheJobs() async {
    print("-- the sheet closes while a job runs")
    let flow = NewProjectFlow()
    let log = Log()
    check(flow.assistant.start("explore:slow", log.work("slow", nanoseconds: 5_000_000_000)), "a slow job starts")
    flow.close()
    check(!flow.store.jobs.isRunning("explore:slow"), "closing frees its key at once")
    check(await waitUntil(1) { log.cancelled == ["slow"] }, "the job is cut off without waiting for its call")
    check(log.written.isEmpty, "a cut off job writes nothing")
    check(flow.assistant.start("explore:slow", log.work("again", nanoseconds: 10_000_000)), "the same key starts again after a close")
    check(await waitUntil { log.written == ["again"] }, "and writes")
}

@MainActor
func closeEndsTheStep() async {
    print("-- the sheet closes while a step is started")
    var fired = 0
    let open = NewProjectFlow()
    open.startDiscard { fired += 1 }
    check(await waitUntil { fired == 1 }, "a step that is not cut off runs to its end")
    let closed = NewProjectFlow()
    closed.startDiscard { fired += 10 }
    closed.close()
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(fired == 1, "a step that the close cut off does not report its end")
}

@MainActor
func storeOutlivesTheSheet() async {
    print("-- the sheet is gone before the job wakes")
    let log = Log()
    weak var weakFlow: NewProjectFlow?
    weak var weakStore: FeatureStore?
    do {
        let flow = NewProjectFlow()
        weakFlow = flow
        weakStore = flow.store
        flow.assistant.start("explore:late", log.work("late", nanoseconds: 400_000_000))
        flow.close()
    }
    check(weakFlow == nil, "the flow is released when the sheet lets go of it")
    check(weakStore != nil, "the store is still there for the job in flight")
    check(await waitUntil { log.woke == ["late"] }, "the cut off job wakes and reads its store without a trap")
    check(log.cancelled == ["late"], "and sees that it was cut off")
    check(await waitUntil { weakStore == nil }, "the store is released once the job has ended")
}

@main
struct Checks {
    static func main() async {
        await startAndRestart()
        await closeEndsTheJobs()
        await closeEndsTheStep()
        await storeOutlivesTheSheet()
        print(failed == 0 ? "All \(passed) checks passed" : "\(failed) FAILED, \(passed) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
