import Foundation
import AppKit
import CoreServices

// Keeps the usage of the AI agents current for the Terminal tab's indicators
// (docs/features/ai-agent-usage-quota-tracker-codex-claude-code): official limit data from the
// vendors with the agents' own stored credentials (DEC-005, DEC-011), local log usage as the
// fallback (DEC-007), refreshed only while an indicator is on screen (DEC-010).

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
    @Published private(set) var detected: [UsageAgent] = []
    @Published private(set) var snapshots: [UsageAgent: AgentUsageSnapshot] = [:]
    /// Advances every tick so countdowns and "updated N min ago" stay current.
    @Published private(set) var now = Date()
    @Published private(set) var refreshing: Set<UsageAgent> = []

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

    private var official: [UsageAgent: OfficialState] = [:]
    private var local: [UsageAgent: LocalState] = [:]
    /// Touched only on `logQueue`.
    private let readers: [UsageAgent: UsageLogReader]
    private let logQueue = DispatchQueue(label: "markview.agent-usage.logs", qos: .utility)
    private var visibleCount = 0
    private var appActive = true
    private var timer: Timer?
    private var eventStream: FSEventStreamRef?

    private init() {
        readers = Dictionary(uniqueKeysWithValues: UsageAgent.allCases.map { ($0, UsageLogReader(agent: $0)) })
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

    private var isRunning: Bool { timer != nil }

    private func updateRunning() {
        let shouldRun = visibleCount > 0 && appActive
        if shouldRun && !isRunning {
            detect()
            startWatching()
            timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
                Task { @MainActor in AgentUsageTracker.shared.tick() }
            }
            tick()
        } else if !shouldRun && isRunning {
            timer?.invalidate()
            timer = nil
            stopWatching()
        }
    }

    private func detect() {
        detected = UsageAgent.allCases.filter(Self.isDetected)
    }

    /// DEC-012: the CLI is found, or its data directory exists.
    static func isDetected(_ agent: UsageAgent) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tool: CLITool = agent == .claude ? .claude : .codex
        return CLIToolLocator.resolve(tool) != nil
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.dataDirectoryName).path)
    }

    static func isHidden(_ agent: UsageAgent) -> Bool {
        UserDefaults.standard.bool(forKey: agent.hiddenKey)
    }

    /// Detected agents the user has not hidden.
    var shownAgents: [UsageAgent] { detected.filter { !Self.isHidden($0) } }

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

    func cooldownRemaining(_ agent: UsageAgent) -> TimeInterval {
        guard let last = official[agent]?.lastManual else { return 0 }
        return max(0, Self.manualCooldown - now.timeIntervalSince(last))
    }

    /// Fetches official data and rescans the logs now. Also the retry after a denied Keychain
    /// access, which is never repeated automatically (DEC-011).
    func refresh(_ agent: UsageAgent) {
        now = Date()
        guard cooldownRemaining(agent) == 0 else { return }
        var state = official[agent] ?? OfficialState()
        state.lastManual = now
        state.blocked = false
        official[agent] = state
        if !state.inFlight { fetchOfficial(agent) }
        local[agent, default: LocalState()].dirty = true
        scanLocal(agent)
    }

    // MARK: - Fallback limit (DEC-014)

    static func limit(for agent: UsageAgent) -> FallbackLimit? {
        guard let data = UserDefaults.standard.data(forKey: agent.limitKey) else { return nil }
        return try? JSONDecoder().decode(FallbackLimit.self, from: data)
    }

    /// Saves the user's limit, or clears it with nil (back to the no-limit state).
    func setLimit(_ limit: FallbackLimit?, for agent: UsageAgent) {
        if let limit, let data = try? JSONEncoder().encode(limit) {
            UserDefaults.standard.set(data, forKey: agent.limitKey)
        } else {
            UserDefaults.standard.removeObject(forKey: agent.limitKey)
        }
        objectWillChange.send()
        rebuild(agent)
    }

    // MARK: - Official data

    private func fetchOfficial(_ agent: UsageAgent) {
        official[agent, default: OfficialState()].inFlight = true
        refreshing.insert(agent)
        Task {
            let result = await OfficialUsageClient.fetch(agent)
            self.applyOfficial(result, for: agent)
        }
    }

    private func applyOfficial(_ result: OfficialUsageClient.Result, for agent: UsageAgent) {
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
            WorkspaceManager.debugLog("agent usage: \(agent.rawValue) official data, \(windows.count) window(s)")
        case .signedOut:
            // Never refreshed by the app; the CLI refreshes its own sign-in on use (DEC-011).
            state.windows = nil
            state.fetchedAt = nil
            state.backoff = 0
            state.nextFetch = time.addingTimeInterval(Self.pollInterval)
            state.note = "Official limit data unavailable — open \(name) to refresh sign-in"
            WorkspaceManager.debugLog("agent usage: \(agent.rawValue) official data unavailable (signed out or expired)")
        case .keychainDenied:
            state.windows = nil
            state.fetchedAt = nil
            state.blocked = true
            state.note = "Official limit data unavailable — Keychain access to \(name)'s sign-in was denied. Click ↻ to try again."
            WorkspaceManager.debugLog("agent usage: \(agent.rawValue) Keychain access denied")
        case .failed(let reason, let retryAfter):
            state.backoff = state.backoff == 0 ? Self.backoffStart : min(state.backoff * 2, Self.backoffCap)
            let wait = max(state.backoff, retryAfter ?? 0)
            state.nextFetch = time.addingTimeInterval(wait)
            state.note = "Couldn't refresh official data (\(reason)); next try in \(UsageFormat.countdown(wait))"
            WorkspaceManager.debugLog("agent usage: \(agent.rawValue) official fetch failed: \(reason)")
        }
        official[agent] = state
        rebuild(agent)
        // Official windows may reach further back than the last log scan (local figures).
        if let since = local[agent]?.scannedSince, requiredSince(agent) < since { scanLocal(agent) }
    }

    /// Cached official windows still worth showing: a window whose reset has passed is outdated.
    private func currentOfficialWindows(_ agent: UsageAgent) -> [QuotaWindow]? {
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
        for agent in UsageAgent.allCases { local[agent, default: LocalState()].dirty = true }
        scanDueLocal()
    }

    private func scanDueLocal() {
        for agent in shownAgents {
            let state = local[agent] ?? LocalState()
            if state.dirty && now.timeIntervalSince(state.lastScan) >= Self.localDebounce { scanLocal(agent) }
        }
    }

    /// The earliest date any shown figure needs: midnight, the user's window, the official windows.
    private func requiredSince(_ agent: UsageAgent) -> Date {
        var since = Calendar.current.startOfDay(for: now)
        if let limit = Self.limit(for: agent), limit.isValid {
            since = min(since, limit.window(containing: now).start)
        }
        for window in currentOfficialWindows(agent) ?? [] {
            if let start = window.start { since = min(since, start) }
        }
        return since
    }

    private func scanLocal(_ agent: UsageAgent) {
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

    private func applyLocal(_ result: Result<[UsageEvent], Error>, since: Date, for agent: UsageAgent) {
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
            WorkspaceManager.debugLog("agent usage: \(agent.rawValue) local logs: \(state.error ?? "")")
        }
        local[agent] = state
        rebuild(agent)
        // A limit or window set meanwhile may need older lines.
        if requiredSince(agent) < since { scanLocal(agent) }
    }

    // MARK: - Snapshot

    private func rebuild(_ agent: UsageAgent) {
        let officialState = official[agent] ?? OfficialState()
        let localState = local[agent] ?? LocalState()
        let windows = currentOfficialWindows(agent)
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

/// Reads an agent's stored credentials read-only on every call and sends them only to that
/// agent's vendor. Nothing is stored, logged or refreshed; redirects are refused so the token
/// cannot follow one to another host.
enum OfficialUsageClient {
    enum Result {
        case success([QuotaWindow])
        /// No credentials, an expired token, or 401/403.
        case signedOut
        case keychainDenied
        case failed(reason: String, retryAfter: TimeInterval?)
    }

    private struct Credential {
        let token: String
        let accountID: String?
    }

    private enum CredentialResult {
        case found(Credential)
        case missing
        case denied
    }

    static func fetch(_ agent: UsageAgent) async -> Result {
        let credential: Credential
        switch await readCredential(agent) {
        case .found(let found): credential = found
        case .missing: return .signedOut
        case .denied: return .keychainDenied
        }
        var request: URLRequest
        switch agent {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .codex:
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            if let account = credential.accountID { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        }
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MarkView", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
        } catch {
            return .failed(reason: (error as? URLError)?.localizedDescription ?? "network error", retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else { return .failed(reason: "no HTTP response", retryAfter: nil) }
        switch http.statusCode {
        case 200:
            let windows = agent == .claude ? OfficialUsageParser.claude(data) : OfficialUsageParser.codex(data, now: Date())
            guard let windows else { return .failed(reason: "response not recognised", retryAfter: nil) }
            return .success(windows)
        case 401, 403:
            return .signedOut
        case 429:
            return .failed(reason: "rate limited", retryAfter: retryAfter(http))
        default:
            return .failed(reason: "HTTP \(http.statusCode)", retryAfter: retryAfter(http))
        }
    }

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

    /// Seconds or an HTTP date.
    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private static func readCredential(_ agent: UsageAgent) async -> CredentialResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude:
            // A credentials file (older installs), otherwise the Keychain item Claude Code writes
            // with /usr/bin/security; reading it with the same tool needs no access prompt.
            let file = home.appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: file) { return claudeCredential(data) }
            let result = await CLIToolLocator.run("/usr/bin/security",
                                                  ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 15)
            switch result.exitCode {
            case 0: return claudeCredential(Data(result.stdout.utf8))
            case 44: return .missing  // errSecItemNotFound
            default: return .denied
            }
        case .codex:
            let file = home.appendingPathComponent(".codex/auth.json")
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String, !token.isEmpty else { return .missing }
            return .found(Credential(token: token, accountID: tokens["account_id"] as? String))
        }
    }

    /// `claudeAiOauth.accessToken`; an expired token is not sent (the refresh token is never used).
    private static func claudeCredential(_ data: Data) -> CredentialResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .missing }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) <= Date() {
            return .missing
        }
        return .found(Credential(token: token, accountID: nil))
    }
}
