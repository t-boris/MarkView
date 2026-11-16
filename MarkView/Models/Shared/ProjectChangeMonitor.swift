import Foundation
import CoreServices

/// Watches a project recursively without traversing its contents on every timer tick.
final class ProjectChangeMonitor {
    /// The stream retains this context, not the monitor. A queued callback therefore cannot
    /// dereference a monitor that was destroyed while its project window was closing.
    private final class Context {
        let root: String
        let includeGenerated: Bool
        let shouldInclude: (String) -> Bool
        let changed: () -> Void
        init(root: String, includeGenerated: Bool, shouldInclude: @escaping (String) -> Bool, changed: @escaping () -> Void) {
            self.root = root; self.includeGenerated = includeGenerated; self.shouldInclude = shouldInclude; self.changed = changed
        }
        func includes(_ path: String) -> Bool {
            guard (path == root || path.hasPrefix(root + "/")), shouldInclude(path) else { return false }
            if includeGenerated { return true }
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative == "docs/handoffs" || relative.hasPrefix("docs/handoffs/") ||
               relative == ".claude/worktrees" || relative.hasPrefix(".claude/worktrees/") { return false }
            return !relative.split(separator: "/").contains { ProjectSearchIndex.excludedDirectories.contains($0.lowercased()) }
        }
    }
    private var stream: FSEventStreamRef?

    init(root: URL, includeGenerated: Bool = false, shouldInclude: @escaping (String) -> Bool = { _ in true }, changed: @escaping () -> Void) {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let box = Context(root: path, includeGenerated: includeGenerated, shouldInclude: shouldInclude, changed: changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Context>.fromOpaque(pointer).retain().toOpaque())
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<Context>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, rawPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            if paths.contains(where: { ($0 as? String).map(box.includes) ?? false }) { box.changed() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "markview.project-change-monitor", qos: .utility))
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
