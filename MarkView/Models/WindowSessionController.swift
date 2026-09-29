import AppKit
import Combine

/// App-owned restoration works even when macOS is set to close windows on quit.
@MainActor
final class WindowSessionController {
    static let shared = WindowSessionController()
    static let sceneID = "workspace"

    private final class Entry {
        weak var window: NSWindow?
        weak var workspace: WorkspaceManager?
        var restoring = true
        var subscriptions = Set<AnyCancellable>()
        var closeDelegate: ProjectOperationWindowCloseDelegate?
        init(window: NSWindow, workspace: WorkspaceManager) {
            self.window = window
            self.workspace = workspace
        }
    }

    private let storage: WindowSessionStorage
    private let loadedArchive: Task<WindowSessionArchive?, Never>
    private var loaded = false
    private var openedStartupWindows = false
    private var restoredFocus = false
    private var pending: [UUID: WorkspaceWindowState] = [:]
    private var order: [UUID] = []
    private var entries: [UUID: Entry] = [:]
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    private(set) var terminating = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.markview.MarkView"
        let directory = bundleID == "com.markview.MarkView" ? "MarkView" : "MarkView-" + bundleID
        let storage = WindowSessionStorage(url: support.appendingPathComponent(directory)
            .appendingPathComponent("windowSessions.json"))
        self.storage = storage
        loadedArchive = Task { await storage.load() }
    }

    func attach(id: UUID, window: NSWindow, workspace: WorkspaceManager, openWindow: (UUID) -> Void) async {
        var closedBeforeLoad = false
        let closeObserver = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .filter { ($0.object as? NSWindow) === window }
            .sink { _ in closedBeforeLoad = true }
        defer { closeObserver.cancel() }
        let archive = await loadedArchive.value
        if !loaded {
            loaded = true
            var windows = archive?.windows ?? []
            // One-time migration from versions that only remembered one folder.
            if archive == nil, let path = UserDefaults.standard.string(forKey: WorkspaceManager.lastFolderKey) {
                windows = [WorkspaceWindowState(id: UUID(), folder: URL(fileURLWithPath: path))]
            }
            order = windows.map(\.id)
            pending = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        }
        guard entries[id] == nil, !terminating, !closedBeforeLoad else { return }

        var state = pending[id]
        if !openedStartupWindows {
            openedStartupWindows = true
            // The launch-created default window takes the first saved session.
            if state == nil, let first = order.first, var initial = pending.removeValue(forKey: first) {
                initial.id = id
                order[0] = id
                pending[id] = initial
                state = initial
            }
        }
        if !order.contains(id) { order.append(id) }
        let entry = Entry(window: window, workspace: workspace)
        entries[id] = entry
        let closeDelegate = ProjectOperationWindowCloseDelegate(previous: window.delegate, workspace: workspace)
        entry.closeDelegate = closeDelegate
        window.delegate = closeDelegate
        // Native restoration otherwise races us and creates extra empty windows.
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
        if state?.frame == nil {
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.center()
        }

        workspace.objectWillChange.merge(with: workspace.layout.objectWillChange)
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &entry.subscriptions)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name)
                .filter { ($0.object as? NSWindow) === window }
                .sink { [weak self] _ in self?.scheduleSave() }
                .store(in: &entry.subscriptions)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .filter { ($0.object as? NSWindow) === window }
            .sink { [weak self] _ in self?.remove(id) }
            .store(in: &entry.subscriptions)

        // Value-based WindowGroup opens each saved identity at most once.
        for other in order where other != id && entries[other] == nil {
            openWindow(other)
        }
        if let state {
            if let frame = state.frame { restoreFrame(frame, on: window) }
            await workspace.restoreWindowState(state)
            if state.minimized { window.miniaturize(nil) }
        }
        guard entries[id] === entry else { return } // closed while its folder was loading
        entry.restoring = false
        pending.removeValue(forKey: id)
        if pending.isEmpty, !restoredFocus {
            restoredFocus = true
            if let first = order.first, let front = entries[first]?.window, !front.isMiniaturized {
                front.makeKeyAndOrderFront(nil)
            }
        }
        scheduleSave()
    }

    private func remove(_ id: UUID) {
        guard !terminating else { return }
        entries.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        order.removeAll { $0 == id }
        scheduleSave()
    }

    private func archive() -> WindowSessionArchive {
        var states = pending
        for (id, entry) in entries where !entry.restoring {
            guard let window = entry.window, let workspace = entry.workspace else { continue }
            var state = workspace.windowState(id: id)
            state.frame = window.frame
            state.minimized = window.isMiniaturized
            states[id] = state
        }
        let frontToBack = NSApp.orderedWindows.compactMap { window in
            entries.first { $0.value.window === window }?.key
        }
        var seen = Set<UUID>()
        let ids = (frontToBack + order).filter { seen.insert($0).inserted }
        return WindowSessionArchive(windows: ids.compactMap { states[$0] })
    }

    private func scheduleSave() {
        guard !terminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard let self, !self.terminating else { return }
            self.revision += 1
            try? await self.storage.save(self.archive(), revision: self.revision)
        }
    }

    func saveBeforeTermination() async throws {
        terminating = true
        saveTask?.cancel()
        // If quit arrives before the first window attached, retain the loaded archive.
        let previous = await loadedArchive.value
        revision += 1
        do {
            try await storage.save(loaded ? archive() : previous ?? WindowSessionArchive(windows: []), revision: revision)
        } catch {
            terminating = false
            throw error
        }
    }

    private func restoreFrame(_ frame: CGRect, on window: NSWindow) {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(max(frame.width, 900), visible.width),
                          height: min(max(frame.height, 600), visible.height))
        let origin = NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                             y: min(max(frame.minY, visible.minY), visible.maxY - size.height))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Intercepts the close button while a project's subprocesses are alive, while
/// forwarding all other window delegate messages to SwiftUI's original delegate.
@MainActor
private final class ProjectOperationWindowCloseDelegate: NSObject, NSWindowDelegate {
    var previous: NSWindowDelegate?
    weak var workspace: WorkspaceManager?
    private var closeAfterStop = false

    init(previous: NSWindowDelegate?, workspace: WorkspaceManager) {
        self.previous = previous
        self.workspace = workspace
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let originalAllows = previous?.windowShouldClose?(sender) ?? true
        guard originalAllows else { return false }
        guard !closeAfterStop, let store = workspace?.projectOperations else { return true }
        let active = store.runs.values.filter(\.isActive)
        guard !active.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop running project operations before closing this window?"
        alert.informativeText = active.map { $0.snapshot.label + ($0.snapshot.environment.map { " (\($0))" } ?? "") }
            .joined(separator: "\n")
        alert.addButton(withTitle: "Keep working")
        alert.addButton(withTitle: "Stop operations and close")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        store.cancelForClose()
        Task { [weak self, weak sender] in
            while store.runs.values.contains(where: \.isActive) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let self, let sender else { return }
            self.closeAfterStop = true
            sender.performClose(nil)
            self.closeAfterStop = false
        }
        return false
    }
}
