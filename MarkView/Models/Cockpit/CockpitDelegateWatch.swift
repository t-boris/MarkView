import Foundation
import Darwin

/// The processes a step's terminal started, followed while the step runs (REQ-002, REQ-003). When a step ends, MarkView ends the
/// terminal's process group; a delegate that left the group (a subagent, a daemon, `setsid`) lives on and may still write to the
/// checkout. The watch remembers every descendant of the terminal's shell it saw, so what is still alive afterwards can be named,
/// blocks a retry, and can be stopped. A process is identified by its id and its start time, so a reused id is not mistaken for it.
@MainActor
final class CockpitDelegateWatch {
    private var seen: [Int32: CockpitProcessRecord] = [:]
    private var task: Task<Void, Never>?
    private let interval: UInt64

    init(intervalSeconds: Double = 2) { interval = UInt64(intervalSeconds * 1_000_000_000) }

    func start(shell: pid_t) {
        task?.cancel()
        seen = [:]
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached { Self.descendants(of: shell) }.value
                guard let self, !Task.isCancelled else { return }
                for record in found where self.seen[record.pid] == nil { self.seen[record.pid] = record }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Stops watching; returns the processes seen during the step, the shell's own group included.
    func stop() -> [CockpitProcessRecord] {
        task?.cancel(); task = nil
        return Array(seen.values).sorted { $0.pid < $1.pid }
    }

    // MARK: The process table

    /// Every live process below `root` in the parent tree, `root` itself excluded.
    nonisolated static func descendants(of root: pid_t) -> [CockpitProcessRecord] {
        let table = processTable()
        var children: [pid_t: [kinfo_proc]] = [:]
        for entry in table { children[entry.kp_eproc.e_ppid, default: []].append(entry) }
        var result: [CockpitProcessRecord] = []
        var queue: [pid_t] = [root]
        var visited: Set<pid_t> = [root]
        while let parent = queue.popLast() {
            for child in children[parent] ?? [] {
                let pid = child.kp_proc.p_pid
                guard visited.insert(pid).inserted else { continue }
                result.append(record(child))
                queue.append(pid)
            }
        }
        return result
    }

    /// Those of `records` that still run: the same id with the same start time.
    nonisolated static func alive(_ records: [CockpitProcessRecord]) -> [CockpitProcessRecord] {
        guard !records.isEmpty else { return [] }
        let live = Dictionary(processTable().map { ($0.kp_proc.p_pid, record($0)) }, uniquingKeysWith: { first, _ in first })
        return records.filter { recorded in
            guard let now = live[recorded.pid] else { return false }
            return abs(now.started - recorded.started) < 0.01
        }
    }

    /// Ends `records` (SIGTERM, then SIGKILL after `grace`) and returns those still alive afterwards. Only processes that are still the
    /// recorded ones are signalled.
    nonisolated static func stop(_ records: [CockpitProcessRecord], grace: TimeInterval = 2) async -> [CockpitProcessRecord] {
        for record in alive(records) { kill(record.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !alive(records).isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        for record in alive(records) { kill(record.pid, SIGKILL) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return alive(records)
    }

    private nonisolated static func record(_ entry: kinfo_proc) -> CockpitProcessRecord {
        var proc = entry.kp_proc
        let command = withUnsafeBytes(of: &proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = proc.p_starttime
        return CockpitProcessRecord(pid: proc.p_pid, started: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000, command: command)
    }

    private nonisolated static func processTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            // Room for processes that start between the two calls.
            size += size / 8
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let result = table.withUnsafeMutableBufferPointer { buffer -> Int32 in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            // A zombie has exited and only waits to be reaped: it can no longer write to the checkout.
            if result == 0 { return table.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { Int32($0.kp_proc.p_stat) != SZOMB } }
            if errno != ENOMEM { return [] }
        }
        return []
    }
}
