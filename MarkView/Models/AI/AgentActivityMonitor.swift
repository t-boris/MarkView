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

    /// The window whose terminals are watched: its sessions, the shown one, and where a model a Claude Code terminal's own log
    /// names (BUG-048) is reported, only when the log belongs to that terminal's process.
    weak var provider: (any AssistantProviding)?
    /// Owns the read of the session stores, so it ends with the folder or the window (AR-19).
    private let tasks: TaskBag

    init(tasks: TaskBag) { self.tasks = tasks }

    private var timer: Timer?
    private var busy = false
    private var seen: [UUID: Seen] = [:]
    static let interval: TimeInterval = 3

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            // The window is gone: the timer goes with it.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.tick() }
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
        let active = provider?.shownID
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
        let watched = (provider?.sessions ?? []).filter { $0.isRunning && $0.profile != .shell }
        guard !watched.isEmpty else {
            if !entries.isEmpty { entries = [] }
            seen = [:]
            return
        }
        busy = true
        let jobs: [Job] = watched.map { (id: $0.id, name: $0.title, directory: $0.directory, profile: $0.profile,
                                  shell: $0.shellPID, printing: $0.printed(within: 6), cached: seen[$0.id],
                                  since: $0.runningSince) }
        tasks.store(Task(priority: .utility) { [weak self] in
            let reading = await Self.read(jobs)
            self?.apply(reading.results, models: reading.models, cancelled: Task.isCancelled)
        }, for: "agent-activity.read")
    }

    private typealias Seen = (url: URL, size: Int, date: Date, activity: AgentActivity?)
    private typealias Job = (id: UUID, name: String, directory: URL, profile: TerminalProfile, shell: pid_t, printing: Bool,
                             cached: Seen?, since: Date?)
    private typealias Reading = (results: [(UUID, String, URL, Int, Date, AgentActivity?)], models: [(UUID, String)])

    /// Reads each watched assistant's own session store, off the main actor; ends early when the window's tasks are cancelled.
    nonisolated private static func read(_ jobs: [Job]) async -> Reading {
        var results: [(UUID, String, URL, Int, Date, AgentActivity?)] = []
        var models: [(UUID, String)] = []
        for job in jobs {
            guard !Task.isCancelled else { break }
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
        return (results, models)
    }

    private func apply(_ results: [(UUID, String, URL, Int, Date, AgentActivity?)], models: [(UUID, String)], cancelled: Bool) {
        busy = false
        guard !cancelled else { return }
        for (id, model) in models { provider?.claudeModelReported(model, terminalID: id) }
        var next: [Entry] = []
        var cache: [UUID: Seen] = [:]
        for (id, name, url, size, date, activity) in results {
            cache[id] = (url, size, date, activity)
            if let activity { next.append(Entry(id: id, name: name, activity: activity)) }
        }
        seen = cache
        if next != entries { entries = next }
    }
}
