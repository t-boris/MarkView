import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Finder Quick Action requests (`AR-19`): the action writes the path of what to open into `markview_open_path.txt`, and the app
/// picks it up. One poll serves the whole app; the app delegate starts it at launch, so a request is taken with or without a window
/// (the app queues what it takes until a window shows it). It is a job of the app's `PollingScheduler` that keeps its cadence while
/// the app is in the background, because the action writes the file while another app (Finder) is in front. A request file is read
/// as `AR-12` and `FU-09` require: no symbolic link, a regular file owned by the user, at most 64 KB, and deleted as soon as it is read.
@MainActor
final class FinderOpenRequests {
    static let shared = FinderOpenRequests()
    nonisolated static let fileName = "markview_open_path.txt"
    /// Both the per-user temporary directory and `/tmp`: the action may write to either.
    nonisolated static var standardCandidates: [String] {
        [FileManager.default.temporaryDirectory.appendingPathComponent(fileName).path, "/tmp/" + fileName]
    }

    private static let pollKey = "finder-open-requests"
    private let scheduler: PollingScheduler
    private let candidates: [String]
    private let interval: TimeInterval

    init(candidates: [String] = FinderOpenRequests.standardCandidates, interval: TimeInterval = 1, scheduler: PollingScheduler? = nil) {
        self.candidates = candidates
        self.interval = interval
        self.scheduler = scheduler ?? .app
    }

    var isPolling: Bool { scheduler.keys.contains(Self.pollKey) }

    /// Starts the poll unless it runs; `handler` takes each request on the main actor.
    func start(handler: @escaping @MainActor ([URL]) -> Void) {
        guard !isPolling else { return }
        let candidates = candidates
        scheduler.every(interval, key: Self.pollKey, pausesWhenHidden: false) {
            if let url = await Self.takeRequest(from: candidates) { handler([url]) }
        }
    }

    func stop() { scheduler.stop(key: Self.pollKey) }

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
