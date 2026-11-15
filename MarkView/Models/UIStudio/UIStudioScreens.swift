import Foundation

/// The application's screens and what Studio has prepared for each (REQ-021, DEC-014): the pure part. The list the assistant found,
/// the scenario made for each main screen ahead of the first click, whether that scenario was seen to reach its screen, and whether
/// the source files named as evidence have changed since. Stored in `.markview/studio/screens.json`, team-owned like the scenarios.
struct StudioScreenBook: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// At most this many screens are prepared ahead; the others are prepared by their first click.
    static let mainLimit = 8

    var version = StudioScreenBook.currentVersion
    /// The application folder, relative to the project (`.` or empty for the project itself).
    var appFolder = ""
    /// When the assistant last listed the screens; nil = never.
    var discovered: Date?
    var entries: [Entry] = []

    enum Status: String, Codable, Sendable {
        /// A scenario is saved for the screen and was not opened yet.
        case prepared
        /// The scenario was opened and reached its screen.
        case verified
        /// Preparing it failed, or the scenario did not reach its screen; `failure` says why.
        case failed
    }

    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var screen: StudioScreen
        var scenarioID: String?
        var status: Status?
        var preparedAt: Date?
        var verifiedAt: Date?
        var failure: String?
        /// Hashes of the source files named as evidence, when the scenario was made: another hash means the screen may have changed.
        var sources: [String: String]?

        var id: String { screen.id }
    }

    /// What the Screens menu says of a screen.
    enum State: String, Sendable {
        case notPrepared, preparing, prepared, ready, needsRefresh, failed

        var title: String {
            switch self {
            case .notPrepared: return "not prepared"
            case .preparing: return "preparing…"
            case .prepared: return "prepared"
            case .ready: return "ready"
            case .needsRefresh: return "needs refresh"
            case .failed: return "failed"
            }
        }

        /// The screen opens at once, without the assistant.
        var opensAtOnce: Bool { self == .prepared || self == .ready }
    }

    init(appFolder: String = "") {
        self.appFolder = appFolder
    }

    func entry(for screen: StudioScreen) -> Entry? { entries.first { $0.id == screen.id } }

    /// The screens prepared ahead: the ones the assistant marked main, at most `mainLimit`; without a mark, the first ones.
    var main: [Entry] {
        let marked = entries.filter { $0.screen.main == true }
        return Array((marked.isEmpty ? entries : marked).prefix(Self.mainLimit))
    }

    /// The id of the scenario made for `screen`: stable for the screen, a legal file name, never a built-in id.
    static func scenarioID(for screen: StudioScreen) -> String {
        "screen-" + String(StudioStore.safeID(screen.name).prefix(40)) + "-" + hex(screen.id)
    }

    /// FNV-1a over the screen's identity, eight hex digits.
    private static func hex(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    /// A new listing: screens that are still there keep what was prepared for them, new ones start empty, screens that are gone are
    /// dropped (their scenarios stay saved). A screen whose own description changed keeps its scenario but loses its verification.
    mutating func merge(found: [StudioScreen], now: Date = Date()) {
        let before = entries
        entries = found.map { screen in
            guard var old = before.first(where: { $0.id == screen.id }) else { return Entry(screen: screen) }
            if old.screen.instructions != screen.instructions || old.screen.source != screen.source || old.screen.description != screen.description {
                old.verifiedAt = nil
                if old.status == .verified { old.status = .prepared }
            }
            old.screen = screen
            return old
        }
        discovered = now
    }

    mutating func markPrepared(_ id: String, scenarioID: String, sources: [String: String], now: Date = Date()) {
        update(id) { entry in
            entry.scenarioID = scenarioID
            entry.status = .prepared
            entry.preparedAt = now
            entry.verifiedAt = nil
            entry.failure = nil
            entry.sources = sources
        }
    }

    mutating func markVerified(_ id: String, scenarioID: String? = nil, sources: [String: String]? = nil, now: Date = Date()) {
        update(id) { entry in
            if let scenarioID { entry.scenarioID = scenarioID }
            if let sources { entry.sources = sources }
            entry.status = .verified
            entry.verifiedAt = now
            entry.preparedAt = entry.preparedAt ?? now
            entry.failure = nil
        }
    }

    mutating func markFailed(_ id: String, _ reason: String) {
        update(id) { entry in
            entry.status = .failed
            entry.failure = String(reason.prefix(300))
        }
    }

    private mutating func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    /// The source files a screen's evidence names (`source` is free text: paths with symbols, separated by commas or lines).
    static func sourcePaths(of screen: StudioScreen) -> [String] {
        let pattern = #"[A-Za-z0-9_@\-./\[\]()]+\.(?:tsx|ts|jsx|js|mjs|cjs|vue|svelte|astro|html|css|swift|json|md|erb|php|py|rb)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = screen.source
        var seen = Set<String>()
        var paths: [String] = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let path = String(text[range])
            guard isRelativeFile(path), seen.insert(path).inserted else { continue }
            paths.append(path)
            if paths.count == 8 { break }
        }
        return paths
    }

    /// A file inside the project: relative, no way out of it.
    private static func isRelativeFile(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.hasPrefix("~") && !path.split(separator: "/").contains("..") && path.count <= 300
    }

    /// Whether any source file the entry was made from has changed since (a file that vanished counts). An entry that remembers
    /// no sources is never stale.
    static func isStale(_ entry: Entry, current: [String: String]) -> Bool {
        guard let sources = entry.sources, !sources.isEmpty else { return false }
        return sources.contains { path, hash in current[path].map { $0 != hash } ?? false }
    }

    func state(of entry: Entry, preparing: Set<String>, current: [String: String]) -> State {
        if preparing.contains(entry.id) { return .preparing }
        guard let status = entry.status else { return .notPrepared }
        // A failure is remembered even though it left no scenario, so that it is not tried again by itself on every open.
        if status == .failed { return .failed }
        guard entry.scenarioID != nil else { return .notPrepared }
        if Self.isStale(entry, current: current) { return .needsRefresh }
        return status == .verified ? .ready : .prepared
    }

    /// The entries still to prepare ahead, in order: main screens nothing was prepared for, or whose sources changed. A failed one is
    /// not tried again by itself (the person's click does).
    func pending(preparing: Set<String>, current: [String: String]) -> [Entry] {
        main.filter { entry in
            [State.notPrepared, .needsRefresh].contains(state(of: entry, preparing: preparing, current: current))
        }
    }
}
