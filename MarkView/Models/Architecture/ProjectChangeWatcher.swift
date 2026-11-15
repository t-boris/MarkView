import Foundation
import CoreServices

/// Reports a change anywhere under a project root to the automatic code analysis
/// (REQ-002 of automatic-code-architecture): an `FSEventStream` on the root, coalesced by
/// FSEvents over `latency` seconds. Changes inside the folders the scanner never reads
/// (`ArchitectureScanner.skippedDirectories`: `.dde`, `.git`, build output, dependencies)
/// are dropped, so the app's own database and cache writes and a build do not count as
/// code changes. The stream's callback runs on a private queue and hops to the main actor
/// only for a change that matters; `stop` ends the stream synchronously with that queue, so
/// no callback outlives the watcher.
final class ProjectChangeWatcher {
    /// Seconds FSEvents waits to coalesce events before the callback runs.
    static let latency: TimeInterval = 3

    let root: URL
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "com.markview.project-change-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    /// The root as FSEvents reports it (symlinks resolved) and as given, for prefix matching.
    private let rootPaths: [String]

    init(root: URL, onChange: @escaping @MainActor () -> Void) {
        self.root = root
        self.onChange = onChange
        let given = root.standardizedFileURL.path
        let resolved = root.resolvingSymlinksInPath().path
        rootPaths = given == resolved ? [given] : [given, resolved]
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            // `kFSEventStreamCreateFlagUseCFTypes`: the paths arrive as a CFArray of CFString.
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray as? [String] ?? []
            watcher.report(paths)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// End the stream. Waits for a callback in flight on the stream's queue, so the
    /// watcher is never used after this returns.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// On the stream's queue: hop to the main actor when any reported folder is one the scanner reads.
    private func report(_ paths: [String]) {
        guard paths.contains(where: { Self.matters($0, rootPaths: rootPaths) }) else { return }
        let onChange = onChange
        Task { @MainActor in onChange() }
    }

    /// Whether a change at `path` (a folder, as FSEvents reports it) can affect the scan:
    /// not inside a skipped directory. A path outside every known root spelling is kept;
    /// a needless refresh is cheap and bounded by the scheduler.
    static func matters(_ path: String, rootPaths: [String]) -> Bool {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let root = rootPaths.first(where: { trimmed == $0 || trimmed.hasPrefix($0 + "/") }) else { return true }
        let relative = trimmed.dropFirst(root.count)
        return !relative.split(separator: "/").contains { ArchitectureScanner.skippedDirectories.contains(String($0)) }
    }
}
