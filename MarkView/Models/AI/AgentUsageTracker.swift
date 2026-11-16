import Foundation
import AppKit
import CoreServices
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// Keeps the usage of the AI agents current for the Terminal tab's indicators
// (docs/features/ai-agent-usage-quota-tracker-codex-claude-code): official limit data from the
// vendors with the agents' own stored credentials (DEC-005, DEC-011), local log usage as the
// fallback (DEC-007), refreshed only while an indicator is on screen (DEC-010). Antigravity has no
// credentials MarkView reads and no local fallback: its own `agy` command answers (DEC-020).

/// What the indicator and the popover show for one agent.
struct AgentUsageSnapshot {
    var state: AgentUsageState
    /// Local usage since midnight; nil when the logs could not be read.
    var today: UsageAmount?
    /// Local usage inside each official window, by window id — informational only (DEC-015).
    var localByWindow: [String: UsageAmount] = [:]
    var recordsCost = false
    var officialUpdatedAt: Date?
    var localUpdatedAt: Date?
    /// Why official data is missing or old, e.g. the sign-in hint (DEC-011).
    var officialNote: String?

    func isStale(now: Date) -> Bool {
        guard case .official = state, let officialUpdatedAt else { return false }
        return now.timeIntervalSince(officialUpdatedAt) > AgentUsageTracker.staleAfter
    }

    /// When the shown values were last refreshed.
    var updatedAt: Date? {
        if case .official = state { return officialUpdatedAt }
        return localUpdatedAt
    }
}

@MainActor
final class AgentUsageTracker: ObservableObject {
    static let shared = AgentUsageTracker()

    // DEC-010 constants, fixed in v1.
    nonisolated static let pollInterval: TimeInterval = 5 * 60
    nonisolated static let manualCooldown: TimeInterval = 60
    nonisolated static let backoffStart: TimeInterval = 5 * 60
    nonisolated static let backoffCap: TimeInterval = 30 * 60
    nonisolated static let localDebounce: TimeInterval = 30
    nonisolated static let staleAfter: TimeInterval = 15 * 60
    private static let tickInterval: TimeInterval = 15

    /// Agents found on this Mac (DEC-012), hidden ones included.
    @Published private(set) var detected: [CLITool] = []
    @Published private(set) var snapshots: [CLITool: AgentUsageSnapshot] = [:]
    /// Advances every tick so countdowns and "updated N min ago" stay current.
    @Published private(set) var now = Date()
    @Published private(set) var refreshing: Set<CLITool> = []

    private struct OfficialState {
        var windows: [QuotaWindow]?
        var fetchedAt: Date?
        var nextFetch = Date.distantPast
        var backoff: TimeInterval = 0
        var lastManual: Date?
        var note: String?
        /// Keychain access was denied: no automatic retry in this session (DEC-011).
        var blocked = false
        var inFlight = false
    }

    private struct LocalState {
        var events: [UsageEvent]?
        var error: String?
        var updatedAt: Date?
        var scannedSince: Date?
        var lastScan = Date.distantPast
        var dirty = true
        var scanning = false
    }

    private var official: [CLITool: OfficialState] = [:]
    private var local: [CLITool: LocalState] = [:]
    /// Touched only on `logQueue`.
    private let readers: [CLITool: UsageLogReader]
    private let logQueue = DispatchQueue(label: "markview.agent-usage.logs", qos: .utility)
    private var visibleCount = 0
    private var appActive = true
    /// The 15 s refresh is a job of the app's scheduler (`AR-19`), which also pauses it while the app is in the background.
    private static let pollKey = "agent-usage"
    private var eventStream: FSEventStreamRef?

    private init() {
        readers = Dictionary(uniqueKeysWithValues: CLITool.usageTracked.compactMap { agent in UsageLogReader(agent: agent).map { (agent, $0) } })
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AgentUsageTracker.shared.setAppActive(true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AgentUsageTracker.shared.setAppActive(false) }
        }
    }

    // MARK: - Visibility (DEC-010: no polling while hidden or in the background)

    func indicatorAppeared() {
        visibleCount += 1
        if visibleCount == 1 { updateRunning() }
    }

    func indicatorDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 { updateRunning() }
    }

    private func setAppActive(_ active: Bool) {
        guard appActive != active else { return }
        appActive = active
        updateRunning()
    }

    private var isRunning: Bool { PollingScheduler.app.keys.contains(Self.pollKey) }

    private func updateRunning() {
        let shouldRun = visibleCount > 0 && appActive
        if shouldRun && !isRunning {
            detect()
            startWatching()
            PollingScheduler.app.every(Self.tickInterval, key: Self.pollKey) { AgentUsageTracker.shared.tick() }
            tick()
        } else if !shouldRun && isRunning {
            PollingScheduler.app.stop(key: Self.pollKey)
            stopWatching()
        }
    }

    private func detect() {
        detected = CLITool.usageTracked.filter(Self.isDetected)
    }

    /// DEC-012: the CLI is found, or its data directory exists.
    static func isDetected(_ agent: CLITool) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CLIToolLocator.resolve(agent) != nil
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.dataDirectoryName).path)
    }

    static func isHidden(_ agent: CLITool) -> Bool {
        Settings.standard.value(Setting.usageHidden(agent.rawValue))
    }

    /// Detected agents the user has not hidden.
    var shownAgents: [CLITool] { detected.filter { !Self.isHidden($0) } }

    private func tick() {
        now = Date()
        for agent in shownAgents {
            let state = official[agent] ?? OfficialState()
            if !state.inFlight && !state.blocked && now >= state.nextFetch { fetchOfficial(agent) }
        }
        scanDueLocal()
        for agent in shownAgents { rebuild(agent) }
    }

    // MARK: - Manual refresh (DEC-010: 60 s cooldown per agent)

    func cooldownRemaining(_ agent: CLITool) -> TimeInterval {
        guard let last = official[agent]?.lastManual else { return 0 }
        return max(0, Self.manualCooldown - now.timeIntervalSince(last))
    }

    /// Fetches official data and rescans the logs now. Also the retry after a denied Keychain
    /// access, which is never repeated automatically (DEC-011).
    func refresh(_ agent: CLITool) {
        now = Date()
        guard cooldownRemaining(agent) == 0 else { return }
        var state = official[agent] ?? OfficialState()
        state.lastManual = now
        state.blocked = false
        official[agent] = state
        if !state.inFlight { fetchOfficial(agent) }
        if agent.hasLocalLogs {
            local[agent, default: LocalState()].dirty = true
            scanLocal(agent)
        }
    }

    // MARK: - Fallback limit (DEC-014)

    static func limit(for agent: CLITool) -> FallbackLimit? {
        guard let data = Settings.standard.stored(Setting.usageLimit(agent.rawValue)) else { return nil }
        return try? JSONDecoder().decode(FallbackLimit.self, from: data)
    }

    /// Saves the user's limit, or clears it with nil (back to the no-limit state).
    func setLimit(_ limit: FallbackLimit?, for agent: CLITool) {
        if let limit, let data = try? JSONEncoder().encode(limit) {
            Settings.standard.set(data, for: Setting.usageLimit(agent.rawValue))
        } else {
            Settings.standard.remove(Setting.usageLimit(agent.rawValue))
        }
        objectWillChange.send()
        rebuild(agent)
    }

    // MARK: - Official data

    private func fetchOfficial(_ agent: CLITool) {
        official[agent, default: OfficialState()].inFlight = true
        refreshing.insert(agent)
        Task {
            let result = await OfficialUsageClient.fetch(agent)
            self.applyOfficial(result, for: agent)
        }
    }

    private func applyOfficial(_ result: UsageFetchResult, for agent: CLITool) {
        let time = Date()
        var state = official[agent] ?? OfficialState()
        state.inFlight = false
        refreshing.remove(agent)
        let name = agent.displayName
        switch result {
        case .success(let windows):
            state.windows = windows
            state.fetchedAt = time
            state.backoff = 0
            state.nextFetch = time.addingTimeInterval(Self.pollInterval)
            state.note = nil
            AppLog.workspace.debug("agent usage: \(agent.rawValue) official data, \(windows.count) window(s)")
        case .signedOut:
            // Never refreshed by the app; the CLI refreshes its own sign-in on use (DEC-011).
            state.windows = nil
            state.fetchedAt = nil
            state.backoff = 0
            state.nextFetch = time.addingTimeInterval(agent.signedOutInterval ?? Self.pollInterval)
            state.note = "Official limit data unavailable — open \(name) to refresh sign-in"
            AppLog.workspace.debug("agent usage: \(agent.rawValue) official data unavailable (signed out or expired)")
        case .keychainDenied:
            state.windows = nil
            state.fetchedAt = nil
            state.blocked = true
            state.note = "Official limit data unavailable — Keychain access to \(name)'s sign-in was denied. Click ↻ to try again."
            AppLog.workspace.debug("agent usage: \(agent.rawValue) Keychain access denied")
        case .failed(let reason, let retryAfter):
            state.backoff = state.backoff == 0 ? Self.backoffStart : min(state.backoff * 2, Self.backoffCap)
            let wait = max(state.backoff, retryAfter ?? 0)
            state.nextFetch = time.addingTimeInterval(wait)
            state.note = "Couldn't refresh official data (\(reason)); next try in \(UsageFormat.countdown(wait))"
            AppLog.workspace.debug("agent usage: \(agent.rawValue) official fetch failed: \(reason)")
        }
        official[agent] = state
        rebuild(agent)
        // Official windows may reach further back than the last log scan (local figures).
        if let since = local[agent]?.scannedSince, requiredSince(agent) < since { scanLocal(agent) }
    }

    /// Cached official windows still worth showing: a window whose reset has passed is outdated.
    private func currentOfficialWindows(_ agent: CLITool) -> [QuotaWindow]? {
        guard let windows = official[agent]?.windows else { return nil }
        let current = windows.filter { ($0.resetsAt ?? .distantFuture) > now }
        return current.isEmpty ? nil : current
    }

    // MARK: - Local logs (DEC-007; debounced to one scan per 30 s)

    private func startWatching() {
        guard eventStream == nil else { return }
        let fm = FileManager.default
        let paths = readers.values.flatMap(\.watchedDirectories).map(\.path).filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            Task { @MainActor in AgentUsageTracker.shared.logsChanged() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, nil, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    /// Any change under the watched log folders. Both agents are marked: a scan without new
    /// lines costs a directory listing.
    private func logsChanged() {
        for agent in CLITool.usageTracked where agent.hasLocalLogs { local[agent, default: LocalState()].dirty = true }
        scanDueLocal()
    }

    private func scanDueLocal() {
        for agent in shownAgents where agent.hasLocalLogs {
            let state = local[agent] ?? LocalState()
            if state.dirty && now.timeIntervalSince(state.lastScan) >= Self.localDebounce { scanLocal(agent) }
        }
    }

    /// The earliest date any shown figure needs: midnight, the user's window, the official windows.
    private func requiredSince(_ agent: CLITool) -> Date {
        var since = Calendar.current.startOfDay(for: now)
        if let limit = Self.limit(for: agent), limit.isValid {
            since = min(since, limit.window(containing: now).start)
        }
        for window in currentOfficialWindows(agent) ?? [] {
            if let start = window.start { since = min(since, start) }
        }
        return since
    }

    private func scanLocal(_ agent: CLITool) {
        var state = local[agent] ?? LocalState()
        guard !state.scanning, let reader = readers[agent] else { return }
        state.scanning = true
        state.dirty = false
        state.lastScan = now
        local[agent] = state
        let since = requiredSince(agent)
        logQueue.async {
            let result = Result { try reader.events(since: since) }
            Task { @MainActor in AgentUsageTracker.shared.applyLocal(result, since: since, for: agent) }
        }
    }

    private func applyLocal(_ result: Result<[UsageEvent], Error>, since: Date, for agent: CLITool) {
        var state = local[agent] ?? LocalState()
        state.scanning = false
        state.updatedAt = Date()
        state.scannedSince = since
        switch result {
        case .success(let events):
            state.events = events
            state.error = nil
        case .failure(let error):
            state.events = nil
            state.error = (error as? UsageLogError)?.message ?? "Local logs could not be read"
            AppLog.workspace.debug("agent usage: \(agent.rawValue) local logs: \(state.error ?? "")")
        }
        local[agent] = state
        rebuild(agent)
        // A limit or window set meanwhile may need older lines.
        if requiredSince(agent) < since { scanLocal(agent) }
    }

    // MARK: - Snapshot

    private func rebuild(_ agent: CLITool) {
        let officialState = official[agent] ?? OfficialState()
        let windows = currentOfficialWindows(agent)
        guard agent.hasLocalLogs else {
            // Antigravity: the official windows, or nothing to show (never a made-up number). Before the first
            // answer there is no state yet rather than "unavailable".
            if let windows {
                snapshots[agent] = AgentUsageSnapshot(state: .official(windows), today: nil, officialUpdatedAt: officialState.fetchedAt,
                                                      localUpdatedAt: nil, officialNote: officialState.note)
            } else if officialState.note != nil || officialState.fetchedAt != nil {
                snapshots[agent] = AgentUsageSnapshot(
                    state: .unavailable(reason: officialState.note == nil ? "waiting for the next refresh" : "no official limit data"),
                    today: nil, officialUpdatedAt: nil, localUpdatedAt: nil, officialNote: officialState.note)
            } else {
                snapshots[agent] = nil
            }
            return
        }
        let localState = local[agent] ?? LocalState()
        let events = localState.events
        let startOfDay = Calendar.current.startOfDay(for: now)
        let limit = Self.limit(for: agent)
        let today = events?.usage(from: startOfDay)
        var limitUsage: UsageAmount?
        if let events, let limit, limit.isValid {
            let interval = limit.window(containing: now)
            limitUsage = events.usage(from: interval.start, to: interval.end)
        }
        let state = AgentUsageState.resolve(official: windows, limit: limit, limitUsage: limitUsage, today: today,
                                            localError: localState.error, now: now)
        var localByWindow: [String: UsageAmount] = [:]
        if let events {
            for window in windows ?? [] where window.modelScope == nil {
                if let start = window.start { localByWindow[window.id] = events.usage(from: start) }
            }
        }
        // Still scanning for the first time: no state yet rather than "unavailable".
        if case .unavailable = state, localState.events == nil, localState.error == nil, officialState.windows == nil {
            snapshots[agent] = nil
            return
        }
        snapshots[agent] = AgentUsageSnapshot(
            state: state, today: today, localByWindow: localByWindow, recordsCost: events?.recordsCost ?? false,
            officialUpdatedAt: windows == nil ? nil : officialState.fetchedAt, localUpdatedAt: localState.updatedAt,
            officialNote: officialState.note)
    }
}

// MARK: - Official data client (DEC-005, REQ-006)

/// What an assistant's usage reader may do (`UsageTransport`): HTTPS to the assistant's own vendor and commands. Credentials
/// are read read-only on every call by the reader and sent only to that vendor; nothing is stored, logged or refreshed;
/// redirects are refused so a token cannot follow one to another host.
struct OfficialUsageClient: UsageTransport {
    static func fetch(_ agent: CLITool) async -> UsageFetchResult {
        guard let usage = agent.provider.usage else { return .failed(reason: "no usage source", retryAfter: nil) }
        return await usage.fetchOfficial(using: OfficialUsageClient())
    }

    func http(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> UsageCommandResult {
        let result = await CLIToolLocator.run(executable, arguments, timeout: timeout)
        return UsageCommandResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    func resolve(_ tool: CLITool) -> String? { CLIToolLocator.resolve(tool) }

    /// No cookies, no cache, nothing written to disk.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
