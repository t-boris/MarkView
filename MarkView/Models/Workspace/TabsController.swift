import AppKit
import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the person answered when asked about unsaved changes.
enum UnsavedChangesAnswer {
    case save, discard, cancel
}

/// The questions a window's tabs ask the person. A window shows alerts (`alerts`); a check passes fixed answers, so closing a modified
/// document can be checked without a dialog on the screen.
struct TabDialogs {
    /// Save, Don't Save or Cancel, for the message and detail given.
    var askToSave: @MainActor (_ message: String, _ detail: String) -> UnsavedChangesAnswer
    /// A save failed while tabs were closing: nothing was closed.
    var reportFailedSave: @MainActor (_ name: String) -> Void
    /// A file cannot be shown as text; true when the person wants it opened in the app the system picks.
    var offerDefaultApp: @MainActor (_ url: URL, _ error: Error) -> Bool

    static let alerts = TabDialogs(
        askToSave: { message, detail in
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .save
            case .alertSecondButtonReturn: return .discard
            default: return .cancel
            }
        },
        reportFailedSave: { name in
            let alert = NSAlert()
            alert.messageText = "Couldn't save \(name)"
            alert.informativeText = "Nothing was closed, so no changes are lost."
            alert.runModal()
        },
        offerDefaultApp: { url, error in
            let alert = NSAlert()
            alert.messageText = "Cannot show \(url.lastPathComponent) as text"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open in Default App")
            return alert.runModal() == .alertSecondButtonReturn
        })
}

/// What happened to the tabs that the rest of the window reacts to. The controller knows nothing of the window around it: it only says so.
enum TabsEvent {
    /// A document was written to disk.
    case saved(URL)
    /// Open tabs took the text of files that changed on disk (an assistant, a command, a branch switch).
    case reloadedFromDisk
    /// The person closed a terminal tab; its shell is the window's to end.
    case terminalClosed(UUID)
    /// The person closed an Insight tab; ending its session in the ordered cleanup (Decision 11 §4) and then dropping the tab are the window's.
    case insightClosed(InsightSession)
}

/// What a feature that works with the open documents needs from its window, and nothing more (`AR-14`, `AR-17`).
@MainActor
protocol TabsProviding: AnyObject {
    /// The tab the person is looking at; nil on the Welcome tab.
    var activeTab: OpenTab? { get }
    /// Shows `url` in a tab of the window.
    func openFile(_ url: URL)
}

/// Everything about the tabs a window has open (`AR-14` step 5): which ones, which is active, opening, saving, closing, reloading what
/// changed on disk, and the scroll position and active heading of each document. Views that show tabs observe this object directly, so
/// typing in the editor redraws what shows the tabs and nothing else (`AR-15`).
@MainActor
final class TabsController: ObservableObject {
    @Published private(set) var openTabs: [OpenTab] = []
    /// -1 is the pinned Welcome tab, also while other tabs are open.
    @Published var activeTabIndex = -1
    /// The banner above the window after a failed save (or a refused autosave of the window session).
    @Published var lastSaveError: String?
    /// Per-tab scroll position and active heading. Neither is a property of `OpenTab`: the editor reports them continuously, and a
    /// change here reaches no view that observes the tabs (`AR-15`).
    let scroll = DocumentScrollSideTable()

    private let eventSubject = PassthroughSubject<TabsEvent, Never>()
    var events: AnyPublisher<TabsEvent, Never> { eventSubject.eraseToAnyPublisher() }

    private let dialogs: TabDialogs
    /// Background work of the tabs: loading a document, the check for files that changed on disk, a data file's notes. Cancelled with
    /// the window (`shutdown`), keyed so a second request replaces the first.
    private let tasks = TaskBag()
    /// Last seen modification dates of open files (to reload what the assistant changed).
    private var openFileDates: [URL: Date] = [:]
    /// Bumped whenever the tabs are emptied, so a document that was still loading for the old folder is dropped when it arrives.
    private var generation = 0


    init(dialogs: TabDialogs = .alerts) {
        self.dialogs = dialogs
    }

    var activeTab: OpenTab? {
        openTabs.indices.contains(activeTabIndex) ? openTabs[activeTabIndex] : nil
    }

    // MARK: - The tabs

    func reset() {
        let removed = openTabs.map(\.id)
        generation += 1
        openTabs = []
        activeTabIndex = -1
        forget(removed)
    }

    func firstIndex(of url: URL) -> Int? {
        openTabs.firstIndex(where: { $0.url == url })
    }

    @discardableResult
    func selectTab(matching url: URL) -> Int? {
        guard let index = firstIndex(of: url) else { return nil }
        activeTabIndex = index
        return index
    }

    func appendTab(_ tab: OpenTab, activate: Bool = true) {
        openTabs.append(tab)
        if activate {
            activeTabIndex = openTabs.count - 1
        }
    }

    func updateTab(at index: Int, _ mutate: (inout OpenTab) -> Void) {
        guard openTabs.indices.contains(index) else { return }
        var tab = openTabs[index]
        mutate(&tab)
        openTabs[index] = tab
    }

    func updateActiveTab(_ mutate: (inout OpenTab) -> Void) {
        updateTab(at: activeTabIndex, mutate)
    }

    func removeTab(at index: Int) {
        guard openTabs.indices.contains(index) else { return }
        let removedID = openTabs[index].id
        openTabs.remove(at: index)
        normalizeActiveTabIndex(preferred: activeTabIndex)
        forget([removedID])
    }

    /// Drag and drop in the tab bar: the tab `id` takes the position `target` (the one it moves before); the active tab stays active.
    func moveTab(id: UUID, to target: Int) {
        guard let from = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let activeID = activeTab?.id
        let tab = openTabs.remove(at: from)
        let destination = min(max(0, target > from ? target - 1 : target), openTabs.count)
        openTabs.insert(tab, at: destination)
        if let activeID, let index = openTabs.firstIndex(where: { $0.id == activeID }) { activeTabIndex = index }
    }

    func keepOnlyTab(at index: Int) {
        guard openTabs.indices.contains(index) else { return }
        let kept = openTabs[index]
        let removed = openTabs.enumerated().compactMap { $0.offset == index ? nil : $0.element.id }
        openTabs = [kept]
        activeTabIndex = 0
        forget(removed)
    }

    /// Keeps the tabs `isIncluded` accepts, in their order. The active tab stays active when it stays open; otherwise `TabClosing` picks
    /// the neighbour (or the Welcome tab).
    func keepTabs(where isIncluded: (OpenTab) -> Bool) {
        let keep = openTabs.map(isIncluded)
        let removed = zip(openTabs, keep).compactMap { $0.1 ? nil : $0.0.id }
        let active = TabClosing.activeIndex(afterKeeping: keep, active: activeTabIndex)
        openTabs = zip(openTabs, keep).filter(\.1).map(\.0)
        activeTabIndex = active
        forget(removed)
    }

    func keepTabs(through index: Int) {
        guard openTabs.indices.contains(index) else { return }
        let removed = openTabs.dropFirst(index + 1).map(\.id)
        openTabs = Array(openTabs.prefix(index + 1))
        normalizeActiveTabIndex(preferred: activeTabIndex)
        forget(removed)
    }

    func normalizeActiveTabIndex(preferred: Int? = nil) {
        let candidate = preferred ?? activeTabIndex

        // -1 selects the pinned Welcome tab, including while other tabs are open.
        if candidate == -1 { activeTabIndex = -1; return }

        guard !openTabs.isEmpty else {
            activeTabIndex = -1
            return
        }

        activeTabIndex = min(max(candidate, 0), openTabs.count - 1)
    }

    /// The per-tab side table drops what it held for tabs that are gone (`FU-11`).
    private func forget(_ removed: [UUID]) {
        for id in removed { scroll.removeTab(id) }
    }

    // MARK: - Opening

    /// Shows `url` in a tab: the one that shows it already, or a new one of the kind the file asks for. A text file is read in the
    /// background and its tab appears when the text is there.
    func openDocument(_ url: URL) {
        if selectTab(matching: url) != nil { return }

        if FileType.from(url: url) == .pdf {
            appendDocumentTab(url, kind: .pdf(PDFReaderController()))
        } else if Archive.isArchive(url) {
            // The archive view lists the entries; nothing is unpacked until one is clicked.
            appendDocumentTab(url, kind: .archive)
        } else if FileType.isData(url) {
            // The page's viewers read data files themselves (they may be binary or very large).
            appendDocumentTab(url, kind: .data)
            openFileDates[url] = BackgroundFileScans.modificationDate(of: url)
            startWatchingOpenFiles()
        } else if FileType.isImage(url) {
            // The image viewer reads the file itself.
            appendDocumentTab(url, kind: .image)
        } else {
            tasks.store(Task { await openTextFile(url) }, for: "open:" + url.path)
        }
    }

    /// Brings the X-Ray tab of `scope` (the project's, a folder's or the pull request's) to the front, opening it under `root` when it
    /// is not there yet.
    func showArchitectureTab(scope: String, root: URL) {
        let isThisTab = { (tab: OpenTab) -> Bool in
            if case .architecture(let shown) = tab.kind { return shown == scope }
            return false
        }
        if let index = openTabs.firstIndex(where: isThisTab) {
            activeTabIndex = index
        } else {
            let marker = ProjectPaths.placeholderName(scope.isEmpty ? "architecture"
                : scope == TabKind.pullRequestScope ? "pr-xray"
                : "architecture-" + String(ContentHash.of(scope).prefix(12)))
            var tab = OpenTab(url: root.appendingPathComponent(marker), content: "", originalContent: "")
            tab.kind = .architecture(scope: scope)
            appendTab(tab)
        }
    }

    /// The text the open tab for `url` holds, unsaved edits included; nil when the file is not open.
    func content(ofOpen url: URL) -> String? {
        openTabs.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.content
    }

    private func appendDocumentTab(_ url: URL, kind: TabKind) {
        var tab = OpenTab(url: url, content: "", originalContent: "")
        tab.kind = kind
        appendTab(tab)
    }

    /// Reads `url` as text and opens its tab. A window that was emptied meanwhile (another folder opened) does not get the tab.
    func openTextFile(_ url: URL) async {
        guard selectTab(matching: url) == nil else { return }
        let opening = generation
        do {
            let content = try await Self.readText(at: url)
            guard opening == generation, selectTab(matching: url) == nil else { return }
            var tab = OpenTab(url: url, content: content, originalContent: content)

            // Extract headings from markdown
            if url.pathExtension.lowercased() == "md" {
                tab.headings = Self.headings(in: content)
            }

            appendTab(tab)
        } catch is CancellationError {
            return
        } catch {
            showReadError(error, url: url)
        }
    }

    /// A file cannot be shown as text: offers to open it in the app the system picks.
    func showReadError(_ error: Error, url: URL) {
        if dialogs.offerDefaultApp(url, error) { NSWorkspace.shared.open(url) }
    }

    /// The image viewer's arrows and slideshow: the image tab of `url` shows `target` instead.
    func showImage(_ target: URL, replacing url: URL) {
        guard let index = firstIndex(of: url), case .image = openTabs[index].kind else { return }
        updateTab(at: index) { $0.url = target }
    }

    /// The image viewer's "Source" (SVG): replace the image tab with the file as text.
    func openImageAsText(_ url: URL) {
        if let index = firstIndex(of: url), case .image = openTabs[index].kind {
            removeTab(at: index)
        }
        tasks.store(Task { await openTextFile(url) }, for: "open:" + url.path)
    }

    /// Extract headings from markdown content
    nonisolated static func headings(in markdown: String) -> [HeadingItem] {
        var headings: [HeadingItem] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
            if level >= 1 && level <= 6 && !text.isEmpty {
                headings.append(HeadingItem(id: UUID().uuidString, level: level, text: String(text)))
            }
        }
        return headings
    }

    /// The disk read of a text file, off the main thread (it is a nonisolated async function) and cancelled with its caller.
    private nonisolated static func readText(at url: URL) async throws -> String {
        try FileType.readText(at: url)
    }

    // MARK: - The editor page

    /// Index of the tab a message from the editor page belongs to (see `EditorDocumentRouting`), or nil when
    /// the message must be dropped. Logs when the page's document is not the selected tab: that is the state
    /// that once let one file's text be saved over another (BUG-031).
    func editorTabIndex(documentID: UUID?, event: String) -> Int? {
        guard let index = EditorDocumentRouting.targetIndex(documentID: documentID, tabIDs: openTabs.map(\.id),
                                                            activeIndex: activeTabIndex) else {
            if documentID != nil { AppLog.workspace.debug("[Editor] \(event) dropped: the tab it belongs to is closed") }
            return nil
        }
        if documentID != nil, index != activeTabIndex {
            let active = activeTab?.displayName ?? "none"
            AppLog.workspace.debug("[Editor] \(event) for \(self.openTabs[index].displayName) while \(active) is selected")
        }
        return index
    }

    /// Update the content of the tab the editor page is showing (`documentID`); a page that names no document
    /// updates the selected tab, as before.
    /// Insight tabs own their content via `InsightSession`; the JS bridge must
    /// not write back into `tab.content` because (a) it would race with the SSE
    /// stream, and (b) `isModified` would flip true and prime an unwanted Cmd+S
    /// write to the placeholder URL.
    func updateTabContent(_ content: String, documentID: UUID?) {
        guard let index = editorTabIndex(documentID: documentID, event: "content update") else { return }
        updateTab(at: index) { tab in
            if !tab.isFileBacked { return }
            tab.content = content
            tab.isModified = (content != tab.originalContent)
        }
    }

    /// Update the headings for the active tab
    func updateActiveTabHeadings(_ headings: [HeadingItem]) {
        updateActiveTab { tab in
            tab.headings = headings
        }
    }

    /// The editor's active heading of the active tab, kept in the side table for the Contents panel.
    func updateActiveHeading(_ headingId: String) {
        guard let tab = activeTab else { return }
        scroll.setActiveHeading(headingId, for: tab.id)
    }

    /// Reload the active tab from disk and return the fresh content for the editor.
    /// Insight tabs are skipped: their URL is a placeholder that never exists on disk
    /// (see `InsightCoordinator.start`). Reading it back would either fail (today) or,
    /// worse, clobber `tab.content` with stale data if a stray write ever produced
    /// the file. Returning nil leaves the insight player's state untouched.
    func reloadActiveTabFromDisk() -> String? {
        let index = activeTabIndex
        guard openTabs.indices.contains(index), openTabs[index].isFileBacked else { return nil }
        guard let content = try? String(contentsOf: openTabs[index].url, encoding: .utf8) else { return nil }
        updateTab(at: index) { tab in
            tab.content = content
            tab.originalContent = content
            tab.isModified = false
        }
        return content
    }

    // MARK: - Saving

    /// Save the active tab's file.
    /// Insight tabs are ephemeral (Decision 10 §7 / Task 7): the placeholder URL
    /// `.insight-<uuid>` must NEVER be written to disk. Cmd+S on an insight tab
    /// is a no-op here — the insight player has its own Save flow that calls
    /// `didRequestInsightSave` (NSSavePanel + sanitized filename + node body only).
    func saveActiveFile() {
        guard let tab = activeTab, tab.isFileBacked else { return }
        saveFile(at: activeTabIndex)
    }

    /// Save the tab the editor page asked to save (`documentID`), which is not always the selected tab: the
    /// page names the document it shows, and only that tab's file is written (BUG-031). A page that names no
    /// document saves the selected tab, as before.
    func saveEditorDocument(documentID: UUID?) {
        guard let index = editorTabIndex(documentID: documentID, event: "save"),
              openTabs[index].isFileBacked else { return }
        saveFile(at: index)
    }

    /// Save a file at the given index.
    /// Defense-in-depth: insight tabs are guarded here too — even if a future
    /// caller forgets the kind-check, the placeholder URL never reaches `write(to:)`.
    func saveFile(at index: Int) {
        guard openTabs.indices.contains(index) else { return }

        let tab = openTabs[index]
        if !tab.isFileBacked { return }
        do {
            try AtomicFile.write(Data(tab.content.utf8), to: tab.url, permissions: nil)
            lastSaveError = nil
            updateTab(at: index) { mutableTab in
                mutableTab.isModified = false
                mutableTab.originalContent = tab.content // new baseline
            }
            eventSubject.send(.saved(tab.url))
        } catch {
            lastSaveError = "Could not save “\(tab.displayName)”: \(error.localizedDescription)"
            AppLog.workspace.error("Error saving file: \(error)")
        }
    }

    // MARK: - Closing

    /// Close a tab at the given index
    func closeTab(at index: Int) {
        guard openTabs.indices.contains(index) else { return }
        let tab = openTabs[index]

        // An Insight tab ends in the ordered cleanup of `InsightCoordinator.close` (Decision 11 §4). Insight tabs are ephemeral and never
        // carry unsaved changes, so the save prompt is skipped for them.
        switch tab.kind {
        case .terminal(let terminalID):
            // A terminal tab: the window ends its shell; there is nothing to save.
            removeTab(at: index)
            eventSubject.send(.terminalClosed(terminalID))
            return
        case .browser(let session):
            session.close()
            removeTab(at: index)
            return
        case .uiStudio(let session):
            // Teardown outlives the tab and the window, so it is not in `tasks`: cancelling it would leave the server running.
            Task { await session.close() }
            removeTab(at: index)
            return
        case .cockpit(let session):
            session.cancel()
            removeTab(at: index)
            return
        case .insight(let session):
            // The window ends the session first and drops the tab afterwards, so the tab stays until its cleanup is done.
            eventSubject.send(.insightClosed(session))
            return
        default:
            break
        }

        if tab.isModified {
            switch dialogs.askToSave("Save changes?", "Do you want to save changes to \(tab.displayName)?") {
            case .save: saveFile(at: index)
            case .cancel: return
            case .discard: break
            }
        }
        removeTab(at: index)
    }

    /// Close every tab showing `url` or something inside it — the item was moved to the Trash,
    /// so nothing is saved: the user chose to let it go.
    func closeTabs(under url: URL) {
        let base = url.standardizedFileURL.path
        for index in openTabs.indices.reversed() {
            let tab = openTabs[index]
            switch tab.kind {
            case .file, .image, .pdf, .archive:
                let path = tab.url.standardizedFileURL.path
                if path == base || path.hasPrefix(base + "/") { removeTab(at: index) }
            default:
                continue
            }
        }
    }

    /// Close all tabs except the one at the given index
    func closeOtherTabs(except index: Int) {
        for (i, tab) in openTabs.enumerated() where i != index { if case .cockpit(let session) = tab.kind { session.cancel() } }
        keepOnlyTab(at: index)
    }

    /// Close all tabs to the right of the given index
    func closeTabsToRight(of index: Int) {
        for (i, tab) in openTabs.enumerated() where i > index { if case .cockpit(let session) = tab.kind { session.cancel() } }
        keepTabs(through: index)
    }

    /// Close every tab that shows a file and keep the tool tabs (Git, Workflow, X-Ray, QA, ...). Unsaved changes are asked about first,
    /// once for all the documents; nothing closes when the person cancels or a save fails.
    func closeDocuments() {
        let documents = openTabs.indices.filter { openTabs[$0].isDocument }
        guard !documents.isEmpty, resolveUnsavedChanges(at: documents, before: "closing the documents") else { return }
        keepTabs { !$0.isDocument }
    }

    /// Close all tabs
    func closeAllTabs() {
        for tab in openTabs { if case .cockpit(let session) = tab.kind { session.cancel() } }
        closeUIStudioSessions()
        reset()
    }

    /// Ends every UI Studio session of this window (closing the window or the folder): development servers a session
    /// started are stopped; servers that were already running are left alone (REQ-006).
    func closeUIStudioSessions() {
        for tab in openTabs {
            if case .uiStudio(let session) = tab.kind {
                Task { await session.close() }
            }
        }
    }

    /// Asks what to do with the unsaved changes of the tabs at `indices` before they close; `closing` finishes the question
    /// ("Save changes to ... before closing the folder?"). True when closing is safe: nothing was unsaved, everything was saved, or the person chose
    /// not to save. False when they cancelled or a save failed, so nothing is closed over unsaved work.
    func resolveUnsavedChanges(at indices: [Int], before closing: String) -> Bool {
        let unsaved = indices.filter { openTabs.indices.contains($0) && openTabs[$0].isModified }
        guard !unsaved.isEmpty else { return true }
        let message = unsaved.count == 1
            ? "Save changes to \(openTabs[unsaved[0]].displayName) before \(closing)?"
            : "Save changes to \(unsaved.count) documents before \(closing)?"
        switch dialogs.askToSave(message, "Your changes will be lost if you don't save them.") {
        case .save:
            unsaved.forEach { saveFile(at: $0) }
            // saveFile only logs write errors — never close over unsaved work.
            if let failed = unsaved.compactMap({ openTabs.indices.contains($0) ? openTabs[$0] : nil }).first(where: { $0.isModified }) {
                dialogs.reportFailedSave(failed.displayName)
                return false
            }
            return true
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    /// Open tabs of moved files (or files inside moved folders) point at their new place.
    func follow(moved: [(URL, URL)]) {
        for (source, destination) in moved {
            for index in openTabs.indices {
                let path = openTabs[index].url.standardizedFileURL.path
                guard path == source.path || path.hasPrefix(source.path + "/") else { continue }
                let moved = URL(fileURLWithPath: destination.path + path.dropFirst(source.path.count))
                updateTab(at: index) { $0.url = moved }
            }
        }
    }

    // MARK: - Files that change on disk

    /// While terminals run, reload open files an assistant (or a command) changed on disk —
    /// only tabs without unsaved edits, so nothing typed here is lost. The loop checks every two seconds; the disk is read
    /// off the main thread and one check ends before the next begins (`AR-42`).
    func startWatchingOpenFiles() {
        guard !tasks.contains(key: "watch") else { return }
        tasks.store(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.reloadChangedOpenFiles()
            }
        }, for: "watch")
    }

    func stopWatchingOpenFiles() {
        tasks.cancel(key: "watch")
    }

    /// `all` reloads every unmodified tab whose file differs, not only files newer than last seen
    /// (a branch switch can restore older modification dates).
    func reloadChangedOpenFiles(all: Bool = false) async {
        var files: [BackgroundFileScans.OpenFile] = []
        for tab in openTabs {
            if case .data = tab.kind {
                // Data tabs: the viewer reads the file again (a followed log scrolls to the new end).
                files.append(.init(url: tab.url, kind: .data, seen: openFileDates[tab.url], loaded: ""))
            } else if tab.isFileBacked && !tab.isModified {
                files.append(.init(url: tab.url, kind: .text, seen: openFileDates[tab.url], loaded: tab.originalContent))
            }
        }
        guard !files.isEmpty else { return }
        let readings = await Self.read(files, all: all)

        var changed = false
        for reading in readings {
            let url = reading.file.url
            openFileDates[url] = reading.date
            guard let index = firstIndex(of: url) else { continue }
            if reading.file.kind == .data {
                guard reading.isNewer, case .data = openTabs[index].kind else { continue }
                updateTab(at: index) { $0.dataRevision += 1 }
                if openTabs[index].notesView {
                    refreshDataNotes(url, revision: openTabs[index].dataRevision)
                }
            } else if let text = reading.changedText {
                // The tab was edited, or reloaded by a faster check, while the file was being read: leave it.
                guard openTabs[index].isFileBacked, !openTabs[index].isModified,
                      openTabs[index].originalContent == reading.file.loaded else { continue }
                updateTab(at: index) { tab in
                    tab.content = text
                    tab.originalContent = text
                    tab.isModified = false
                }
                changed = true
            }
        }
        if changed { eventSubject.send(.reloadedFromDisk) }
    }

    private nonisolated static func read(_ files: [BackgroundFileScans.OpenFile], all: Bool) async -> [BackgroundFileScans.OpenFileReading] {
        BackgroundFileScans.read(files, all: all)
    }

    /// Keep a data file's textual Explain source in step with the viewer's reloads.
    private func refreshDataNotes(_ url: URL, revision: Int) {
        tasks.store(Task { [weak self] in
            let text = try? await Self.readText(at: url)
            guard let self, let index = self.firstIndex(of: url), case .data = self.openTabs[index].kind,
                  self.openTabs[index].notesView, self.openTabs[index].dataRevision == revision else { return }
            self.updateTab(at: index) { tab in
                if let text {
                    tab.content = text
                    tab.originalContent = text
                } else {
                    tab.notesView = false
                }
            }
        }, for: "notes:" + url.path)
    }

    /// The window is closing: nothing the tabs started keeps running, and the UI Studio sessions end with it.
    func shutdown() {
        closeUIStudioSessions()
        tasks.cancelAll()
    }
}
