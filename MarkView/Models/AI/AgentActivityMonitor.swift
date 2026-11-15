import Foundation

/// Watches the assistants running in a window's AI terminals (Claude Code, Codex, Cline, Copilot, Antigravity)
/// and publishes what each one is doing, for the tabs and the toolbar. Reads each one's own session
/// store off the main thread every few seconds, and only while an assistant terminal is running.
@MainActor
final class AgentActivityMonitor: ObservableObject {
    struct Entry: Equatable, Identifiable {
        let id: UUID
        let name: String
        let activity: AgentActivity
    }

    /// One entry per running assistant terminal whose session can be read.
    @Published private(set) var entries: [Entry] = []

    /// The terminals to watch and the shown one; set by the workspace.
    var terminals: () -> [TerminalSession] = { [] }
    var activeTerminalID: () -> UUID? = { nil }
    /// A Claude Code terminal's own log names the model it runs now (BUG-048). Called for the
    /// terminals whose log was read this round, only when the log belongs to that terminal's process.
    var onClaudeModel: (UUID, String) -> Void = { _, _ in }

    private var timer: Timer?
    private var busy = false
    private var seen: [UUID: (url: URL, size: Int, date: Date, activity: AgentActivity?)] = [:]
    static let interval: TimeInterval = 3

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// What the toolbar shows: the active terminal's assistant, or the first working one.
    var headline: Entry? {
        let active = activeTerminalID()
        return entries.first { $0.activity.state != .idle && $0.id == active }
            ?? entries.first { $0.activity.state != .idle }
            ?? entries.first { $0.id == active } ?? entries.first
    }

    /// Working assistants other than the headline.
    var othersWorking: Int {
        entries.filter { $0.activity.state != .idle && $0.id != headline?.id }.count
    }

    private func tick() {
        guard !busy else { return }
        let watched = terminals().filter { $0.isRunning && $0.profile != .shell }
        guard !watched.isEmpty else {
            if !entries.isEmpty { entries = [] }
            seen = [:]
            return
        }
        busy = true
        let jobs = watched.map { (id: $0.id, name: $0.title, directory: $0.directory, profile: $0.profile,
                                  shell: $0.shellPID, printing: $0.printed(within: 6), cached: seen[$0.id],
                                  since: $0.runningSince) }
        Task.detached(priority: .utility) { [weak self] in
            var results: [(UUID, String, URL, Int, Date, AgentActivity?)] = []
            var models: [(UUID, String)] = []
            for job in jobs {
                switch job.profile {
                case .claude, .codex:
                    // The log of this terminal's own process; the newest log of the folder may be another tab's.
                    let own = job.profile == .claude ? AgentActivityLog.claudeLog(shell: job.shell) : nil
                    let url = job.profile == .codex ? AgentActivityLog.newestCodexLog(for: job.directory)
                        : (own ?? AgentActivityLog.newestClaudeLog(for: job.directory))
                    guard let url, let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let date = values.contentModificationDate else { continue }
                    let size = values.fileSize ?? 0
                    if let cached = job.cached, cached.url == url, cached.size == size, cached.date == date,
                       cached.activity?.state != .working {
                        results.append((job.id, job.name, url, size, date, cached.activity))
                        continue
                    }
                    let lines = AgentActivityLog.tail(of: url)
                    if own != nil, let reading = ClaudeSessionModel.reading(lines: lines, since: job.since) {
                        models.append((job.id, reading.model))
                    }
                    let activity = job.profile == .codex ? AgentActivityParser.codex(lines: lines)
                                                         : AgentActivityParser.claude(lines: lines)
                    results.append((job.id, job.name, url, size, date, activity))
                case .cline:
                    guard let session = AgentActivityLog.clineSession(directory: job.directory, shell: job.shell),
                          let data = try? Data(contentsOf: session.messages) else { continue }
                    results.append((job.id, job.name, session.messages, data.count, Date(),
                                    AgentActivityParser.cline(messagesJSON: data, status: session.status)))
                case .copilot:
                    guard let turn = AgentActivityLog.copilotTurn(directory: job.directory) else { continue }
                    results.append((job.id, job.name, job.directory, 0, Date(),
                                    AgentActivityParser.copilot(userMessage: turn.user, response: turn.response, busy: job.printing)))
                case .antigravity:
                    guard let conversation = AgentActivityLog.antigravityConversation(directory: job.directory) else { continue }
                    results.append((job.id, job.name, job.directory, 0, Date(),
                                    AgentActivityParser.antigravity(title: conversation.title, preview: conversation.preview,
                                                                    status: conversation.status, busy: job.printing)))
                case .shell:
                    break
                }
            }
            await self?.apply(results, models: models)
        }
    }

    private func apply(_ results: [(UUID, String, URL, Int, Date, AgentActivity?)], models: [(UUID, String)]) {
        busy = false
        for (id, model) in models { onClaudeModel(id, model) }
        var next: [Entry] = []
        var cache: [UUID: (url: URL, size: Int, date: Date, activity: AgentActivity?)] = [:]
        for (id, name, url, size, date, activity) in results {
            cache[id] = (url, size, date, activity)
            if let activity { next.append(Entry(id: id, name: name, activity: activity)) }
        }
        seen = cache
        if next != entries { entries = next }
    }
}
