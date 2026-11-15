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
    /// An assistant terminal's own log names the model it runs now (BUG-048, Claude Code). Called for the
    /// terminals whose log was read this round, only when the log belongs to that terminal's process.
    var onModelReading: (UUID, String) -> Void = { _, _ in }

    private var timer: Timer?
    private var busy = false
    private var seen: [UUID: ActivityCache] = [:]
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
        let watched = terminals().filter { $0.isRunning && $0.profile.tool != nil }
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
                guard let reader = job.profile.tool?.provider.activity,
                      let read = reader.read(ActivityRequest(directory: job.directory, shell: job.shell, printing: job.printing,
                                                             cached: job.cached, since: job.since)) else { continue }
                results.append((job.id, job.name, read.source, read.size, read.date, read.activity))
                if let model = read.model { models.append((job.id, model)) }
            }
            await self?.apply(results, models: models)
        }
    }

    private func apply(_ results: [(UUID, String, URL, Int, Date, AgentActivity?)], models: [(UUID, String)]) {
        busy = false
        for (id, model) in models { onModelReading(id, model) }
        var next: [Entry] = []
        var cache: [UUID: ActivityCache] = [:]
        for (id, name, url, size, date, activity) in results {
            cache[id] = ActivityCache(url: url, size: size, date: date, activity: activity)
            if let activity { next.append(Entry(id: id, name: name, activity: activity)) }
        }
        seen = cache
        if next != entries { entries = next }
    }
}
