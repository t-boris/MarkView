import Foundation

/// Finder Quick Action requests (`AR-19`): the action writes the path of what to open into `markview_open_path.txt`, and the app
/// picks it up. One poll serves the whole app, runs only while a window is open (a request waits in its file until then), and lives
/// in a `TaskBag` that `stop()` empties. A request file is read as `AR-12` and `FU-09` require: no symbolic link, a regular file
/// owned by the user, at most 64 KB, and deleted as soon as it is read.
@MainActor
final class FinderOpenRequests {
    static let shared = FinderOpenRequests()
    nonisolated static let fileName = "markview_open_path.txt"
    /// Both the per-user temporary directory and `/tmp`: the action may write to either.
    nonisolated static var standardCandidates: [String] {
        [FileManager.default.temporaryDirectory.appendingPathComponent(fileName).path, "/tmp/" + fileName]
    }

    private static let pollKey = "poll"
    private let tasks = TaskBag()
    private let candidates: [String]
    private let interval: UInt64

    init(candidates: [String] = FinderOpenRequests.standardCandidates, interval: UInt64 = 1_000_000_000) {
        self.candidates = candidates
        self.interval = interval
    }

    var isPolling: Bool { tasks.contains(key: Self.pollKey) }

    /// Starts the poll unless it runs; `handler` takes each request on the main actor.
    func start(handler: @escaping @MainActor ([URL]) -> Void) {
        guard !isPolling else { return }
        let candidates = candidates, interval = interval
        tasks.store(Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                if let url = await Self.takeRequest(from: candidates) { handler([url]) }
            }
        }, for: Self.pollKey)
    }

    func stop() { tasks.cancel(key: Self.pollKey) }

    /// The request in the first of `paths` that holds one, which is deleted; nil when none does. It reads files, so it runs off the
    /// main thread.
    nonisolated static func takeRequest(from paths: [String]) async -> URL? {
        let fm = FileManager.default
        for path in paths {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else {
                close(fd)
                continue
            }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while data.count < 65536 {
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 { data.append(buf, count: n) } else { break }
            }
            close(fd)
            // Delete immediately so the request is not processed twice.
            try? fm.removeItem(atPath: path)
            guard let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            return URL(fileURLWithPath: content)
        }
        return nil
    }
}
