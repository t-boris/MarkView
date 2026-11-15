import AppKit
import Combine
import Foundation

/// The one place that polls (`AR-19`): periodic jobs that run only while somebody can see their result.
///
/// A job runs while the app is active and, for a scheduler that follows a window, while that window is on screen (not occluded, not
/// miniaturized). When either ends, every job stops where it is, including a run in progress, and nothing ticks until both are back;
/// then a job whose interval has passed runs at once, and the others wait for what is left of theirs. A job is keyed: scheduling a key
/// again replaces the job, and `stop`/`stopAll` end it, so the owner (a window, a tool tab, the app) cancels everything it started.
///
/// The clock and the sleep are parameters so a test drives time by hand; nothing in the app sets them.
@MainActor
public final class PollingScheduler {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    public typealias Now = @Sendable () -> Date

    private struct Job {
        var interval: TimeInterval
        var body: @MainActor () async -> Void
        var lastRun: Date
        var task: Task<Void, Never>?
    }

    private var jobs: [String: Job] = [:]
    private let sleep: Sleep
    private let now: Now
    private var appActive: Bool
    private var windowVisible = true
    private var observers: Set<AnyCancellable> = []

    /// The scheduler of the app's own, long-lived work (the Finder hand-off, the usage chip, agent logs): it follows whether the app is
    /// active and has no window. A window's polls use the scheduler its window made with `follow(window:)`.
    public static let app: PollingScheduler = {
        let scheduler = PollingScheduler()
        scheduler.followApp()
        return scheduler
    }()

    public init(isAppActive: Bool = true,
                sleep: @escaping Sleep = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
                now: @escaping Now = { Date() }) {
        appActive = isAppActive
        self.sleep = sleep
        self.now = now
    }

    /// Whether jobs run now.
    public var isVisible: Bool { appActive && windowVisible }
    /// The keys of the jobs that are scheduled, running or paused.
    public var keys: Set<String> { Set(jobs.keys) }
    /// How many scheduled jobs are waiting for their next run (not paused).
    public var runningCount: Int { jobs.values.filter { $0.task != nil }.count }

    /// Runs `body` every `interval` seconds while visible, replacing the job of that key. With `immediately` the first run is now.
    public func every(_ interval: TimeInterval, key: String, immediately: Bool = false, _ body: @escaping @MainActor () async -> Void) {
        jobs[key]?.task?.cancel()
        jobs[key] = Job(interval: interval, body: body, lastRun: immediately ? .distantPast : now(), task: nil)
        start(key, after: immediately ? 0 : interval)
    }

    /// Ends the job of `key`.
    public func stop(key: String) {
        jobs.removeValue(forKey: key)?.task?.cancel()
    }

    /// Ends every job and stops following the app and the window: the owner closes.
    public func stopAll() {
        let all = jobs.values
        jobs.removeAll()
        for job in all { job.task?.cancel() }
        observers.removeAll()
    }

    /// The app became active or resigned.
    public func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        visibilityChanged()
    }

    /// The window this scheduler follows became visible or hidden (occluded, miniaturized).
    public func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        visibilityChanged()
    }

    // MARK: Running

    private func visibilityChanged() {
        if isVisible {
            for key in jobs.keys where jobs[key]?.task == nil {
                guard let job = jobs[key] else { continue }
                start(key, after: max(0, job.interval - now().timeIntervalSince(job.lastRun)))
            }
        } else {
            for key in jobs.keys {
                jobs[key]?.task?.cancel()
                jobs[key]?.task = nil
            }
        }
    }

    private func start(_ key: String, after delay: TimeInterval) {
        guard isVisible, var job = jobs[key], job.task == nil else { return }
        let sleep = sleep
        job.task = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                if wait > 0 { do { try await sleep(wait) } catch { return } }
                guard !Task.isCancelled, let self, let interval = await self.run(key) else { return }
                wait = interval
            }
        }
        jobs[key] = job
    }

    /// One run of the job of `key`; its interval for the next one, or nil when the job ended or paused meanwhile.
    private func run(_ key: String) async -> TimeInterval? {
        guard isVisible, let job = jobs[key] else { return nil }
        jobs[key]?.lastRun = now()
        await job.body()
        guard jobs[key] != nil, isVisible else {
            // A run that visibility cut short counts as not run, so that the job runs again as soon as it is back.
            jobs[key]?.lastRun = .distantPast
            return nil
        }
        return job.interval
    }

    // MARK: Following the app and a window

    /// Follows whether the app is active.
    public func followApp() {
        appActive = NSApp?.isActive ?? true
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setAppActive(true) }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.setAppActive(false) }
            .store(in: &observers)
    }

    /// Follows the app and one window: hidden while the window is occluded (covered, on another Space) or miniaturized.
    public func follow(window: NSWindow) {
        followApp()
        windowVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self, weak window] _ in
                    guard let window else { return }
                    self?.setWindowVisible(window.occlusionState.contains(.visible) && !window.isMiniaturized)
                }
                .store(in: &observers)
        }
    }
}
