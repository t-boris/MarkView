import AppKit
import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
import UniformTypeIdentifiers

/// What Recursive Insight needs from the window it runs in: the tab strip that shows a session. The open folder, the project whose
/// assistant answers and its database come from the window's `ProjectProviding`. `WorkspaceManager` conforms; a test supplies a
/// stand-in.
@MainActor
protocol InsightHost: AnyObject {
    /// The sessions that have a tab, in tab order.
    var insightSessions: [InsightSession] { get }
    /// The session of the selected tab, when that tab is an insight.
    var activeInsightSession: InsightSession? { get }
    /// Adds a tab for `session` (its placeholder URL is never written to disk) and selects it.
    func showInsightTab(_ session: InsightSession, placeholder: URL)
    /// Drops the tab of the session; the session itself has ended.
    func removeInsightTab(sessionID: UUID)
}

/// Recursive Insight of one window: starts a session in a tab, answers the iframe player's bridge messages, exports the archive
/// and ends sessions in the order Decision 11 §4 requires. It owns the graph engine over the open folder's database; the sessions
/// themselves live in their tabs. Every task it starts is kept in the window's `TaskBag`, so closing the folder cancels it.
@MainActor
final class InsightCoordinator {
    private weak var host: InsightHost?
    private let project: any ProjectProviding
    private let tasks: TaskBag
    /// Sent when the page that shows the sessions must drop the blob URLs the insight iframe made for the vendored libraries (the first
    /// step of closing an insight tab). The editor page listens while it routes an insight tab.
    let blobReleases = PassthroughSubject<Void, Never>()

    init(host: InsightHost, project: any ProjectProviding, tasks: TaskBag) {
        self.host = host
        self.project = project
        self.tasks = tasks
    }

    /// The engine that searches the project's database; nil until the workspace has opened it.
    private var graphRAG: GraphRAG? { project.database.map(GraphRAG.init(db:)) }

    // MARK: - Starting a session

    /// Recursive Insight of the open folder, or of one of its folders (`target` a directory) or one document (`target` a Markdown
    /// file): checks the folder, the assistant and the engine, lists the Markdown files, builds the session with its cache
    /// (`<root>/.markview-insight/`, whichever sub-folder or file is analysed), shows it in a new tab and starts the root summary.
    func start(at target: URL? = nil, title: String? = nil) {
        guard let rootURL = project.root else {
            Self.alert("No folder open", "Open a folder before starting Recursive Insight.")
            return
        }
        let target = target?.standardizedFileURL ?? rootURL
        let targetIsFile = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
        let folderURL = targetIsFile ? target.deletingLastPathComponent() : target

        let aiProject = project.aiProject
        let tool = AIAssistantPreferences.backend(project: aiProject)
        guard CLIToolLocator.resolve(tool) != nil else {
            Self.alert("\(tool.displayName) not found", "Set its path in DDE Settings → AI CLI Tools, or choose the other assistant.")
            return
        }
        guard let graphRAG else {
            Self.alert("Workspace not ready", "Wait for the folder to finish opening, then try again.")
            return
        }

        let mdFiles = targetIsFile ? [target] : project.markdownFiles(in: folderURL)
        guard !mdFiles.isEmpty else {
            Self.alert("No markdown files", "This folder contains no .md files for Recursive Insight to summarize.")
            return
        }

        let cache: InsightCache
        do {
            cache = try InsightCache(workspaceURL: rootURL, sessionId: UUID())
        } catch {
            Self.alert("Cannot start Recursive Insight", "Failed to initialise insight cache: \(error.localizedDescription)")
            return
        }
        let session = InsightSession(
            folderURL: folderURL,
            mdFiles: mdFiles,
            graphRAG: graphRAG,
            cache: cache,
            project: aiProject,
            title: title ?? (targetIsFile ? target.deletingPathExtension().lastPathComponent : nil)
        )
        // The placeholder only lets `OpenTab.url`, `displayName` and the other file-only readers work without a special case.
        host?.showInsightTab(session, placeholder: folderURL.appendingPathComponent(".insight-\(session.id.uuidString)"))
        run("generate", session) { await $0.generateRoot() }
    }

    // MARK: - Ending sessions

    /// Closes the tab of `session` in the ordered cleanup of Decision 11 §4: the page revokes its blob URLs first, so no new
    /// emission can re-create one; then the session's generation ends (parallel section tasks and an in-flight ZIP run unwind
    /// cooperatively); then the tab goes and the session is released. The cache stays on disk, so reopening the insight on the
    /// folder reuses the cached HTML instead of running the assistant again.
    func close(_ session: InsightSession) {
        let id = session.id
        tasks.store(Task { [weak self] in
            self?.blobReleases.send()
            await session.cancel()
            self?.host?.removeInsightTab(sessionID: id)
        }, for: "insight.close.\(id)")
    }

    /// Ends the generation of every session in a tab (the folder closes or its data is removed); the tabs are the caller's.
    func cancelSessions() {
        for session in host?.insightSessions ?? [] {
            tasks.store(Task { await session.cancel() }, for: "insight.cancel.\(session.id)")
        }
    }

    // MARK: - Bridge messages from the iframe player

    /// Runs a session action on its own task, keyed by action and session so a task of the same kind it replaces is cancelled.
    private func run(_ action: String, _ session: InsightSession, _ work: @escaping @MainActor (InsightSession) async -> Void) {
        tasks.store(Task { await work(session) }, for: "insight.\(action).\(session.id)")
    }

    private func session(id: String) -> InsightSession? {
        host?.insightSessions.first { $0.id.uuidString == id }
    }

    /// The iframe finished loading. Logged for diagnostics only: the 10 s load timeout is enforced by the parent JS.
    func didReceiveInsightIframeReady(sessionId: String, nodeId: String) {
        guard session(id: sessionId) != nil else {
            AppLog.insight.notice("didReceiveInsightIframeReady: no session for id \(InsightSession.sanitizeForLog(sessionId)) (tab closed?)")
            return
        }
        AppLog.insight.notice("iframe ready for session \(InsightSession.sanitizeForLog(sessionId)) node \(InsightSession.sanitizeForLog(nodeId))")
    }

    /// A 🤿 deep-dive control was clicked: `(sessionId, sectionId, topicIndex)`. The section must be in the current node's skeleton
    /// and the index inside its topics; `session.expand` checks again (never trust the page, even after the bridge's schema check).
    func didRequestInsightDeepDive(sessionId: String, sectionId: String, topicIndex: Int) {
        guard let session = session(id: sessionId) else {
            AppLog.insight.notice("didRequestInsightDeepDive: no session for id \(InsightSession.sanitizeForLog(sessionId)) (tab closed?)")
            return
        }
        guard let skeleton = session.currentNode()?.skeleton else {
            AppLog.insight.notice("didRequestInsightDeepDive: no skeleton on current node for session \(InsightSession.sanitizeForLog(sessionId))")
            return
        }
        guard let section = skeleton.sections.first(where: { $0.id == sectionId }) else {
            AppLog.insight.error("didRequestInsightDeepDive: unknown sectionId \(InsightSession.sanitizeForLog(sectionId)) for session \(InsightSession.sanitizeForLog(sessionId))")
            return
        }
        guard let topics = section.deepDiveTopics, topicIndex >= 0, topicIndex < topics.count else {
            AppLog.insight.notice("didRequestInsightDeepDive: topicIndex \(topicIndex) out of bounds for section \(InsightSession.sanitizeForLog(sectionId)) (topics: \(section.deepDiveTopics?.count ?? 0))")
            return
        }
        run("expand", session) { await $0.expand(sectionId: sectionId, topicIndex: topicIndex) }
    }

    /// A breadcrumb was clicked: switches to a cached node, no assistant call. The node id must be a UUID and a member of the
    /// session's manifest (a compromised page could forge a click for any id).
    func didRequestInsightBreadcrumb(sessionId: String, nodeId: String) {
        guard let session = session(id: sessionId) else {
            AppLog.insight.notice("didRequestInsightBreadcrumb: no session for id \(InsightSession.sanitizeForLog(sessionId)) (tab closed?)")
            return
        }
        guard let uuid = UUID(uuidString: nodeId) else {
            AppLog.insight.error("didRequestInsightBreadcrumb: invalid nodeId \(InsightSession.sanitizeForLog(nodeId))")
            return
        }
        guard session.nodes[uuid] != nil else {
            AppLog.insight.notice("didRequestInsightBreadcrumb: nodeId \(InsightSession.sanitizeForLog(nodeId)) not in session manifest")
            return
        }
        run("navigate", session) { await $0.navigateTo(nodeId: uuid) }
    }

    /// The selected tab's session, for the messages that carry no session id (one active session per page in v2).
    private func activeSession(_ message: String) -> InsightSession? {
        guard let session = host?.activeInsightSession else {
            AppLog.insight.notice("\(message): no active insight session")
            return nil
        }
        return session
    }

    /// ↑ Up: navigates to the current node's parent; nothing at the root.
    func didRequestInsightUp() {
        guard let session = activeSession("didRequestInsightUp") else { return }
        guard let parentId = session.currentNode()?.parentId else {
            AppLog.insight.notice("didRequestInsightUp: already at root for session \(InsightSession.sanitizeForLog(session.id.uuidString))")
            return
        }
        run("navigate", session) { await $0.navigateTo(nodeId: parentId) }
    }

    /// ⟳ Regenerate: wipes the persistent snapshot of this folder and runs phases 1 and 2 again (the output was unsatisfying or
    /// the source files changed).
    func didRequestInsightRegenerate() {
        guard let session = activeSession("didRequestInsightRegenerate") else { return }
        run("generate", session) { await $0.regenerateRoot() }
    }

    /// A custom topic typed into the footer: a child of the current node over all source files.
    func didRequestInsightCustomDeepDive(topic: String) {
        guard let session = activeSession("didRequestInsightCustomDeepDive") else { return }
        run("expand", session) { await $0.expandCustom(topic: topic) }
    }

    /// "🤿×N Explore all topics": every deep-dive topic of the current node, one after the other.
    func didRequestInsightExploreAll(depth: Int) {
        guard let session = activeSession("didRequestInsightExploreAll") else { return }
        run("explore", session) { await $0.expandAllTopicsOnCurrentNode(depth: depth) }
    }

    /// "↻ Retry this section" in a failed-section placeholder: phase 2 again for that one section of the current node.
    func didRequestInsightRetrySection(sectionId: String) {
        guard let session = activeSession("didRequestInsightRetrySection") else { return }
        run("retry", session) { await $0.retrySection(sectionId: sectionId) }
    }

    /// Save: opens the archive export of the selected tab's session.
    func didRequestInsightSave() {
        guard let session = activeSession("didRequestInsightSave") else { return }
        exportArchive(sessionId: session.id.uuidString)
    }

    // MARK: - Archive export

    /// Exports a session as a self-contained ZIP (Decision 7). After the save panel (`<folder>_insight_<time>.zip`; the extension
    /// is forced to `.zip`):
    ///   1. every node's HTML is written again from the in-memory tree with the current template, so the archive carries recent
    ///      CSS and bootstrap changes and the content of retried sections that is not cached yet;
    ///   2. the cache's staging folder is copied to a fresh temporary one, so rewriting never touches what the app still reads;
    ///   3. the copy is rewritten to navigate standalone (`InsightArchiveExport.rewriteForStandalone`);
    ///   4. `InsightArchiveExporter` runs `/usr/bin/zip` with an argument array, no shell, and moves the result into place atomically;
    ///   5. the temporary copy is removed whatever the outcome.
    /// The node tree is read here on the main actor before the task starts, so navigation cannot change it while it is walked.
    func exportArchive(sessionId: String) {
        guard let session = session(id: sessionId) else {
            AppLog.insight.notice("exportInsightArchive: no session for id \(InsightSession.sanitizeForLog(sessionId))")
            return
        }

        let panel = NSSavePanel()
        if let zipType = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zipType] }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = InsightArchiveExport.defaultFilename(folderName: session.folderURL.lastPathComponent)
        guard panel.runModal() == .OK, let pickedURL = panel.url else { return }
        let destinationURL = pickedURL.pathExtension.lowercased() == "zip"
            ? pickedURL : pickedURL.deletingPathExtension().appendingPathExtension("zip")

        let nodeChildMap = InsightArchiveExport.childMap(nodes: session.nodes)
        let rootNodeId = session.nodes.values.first { $0.parentId == nil }?.id
        let cache = session.cache

        for (id, node) in session.nodes {
            guard let skeleton = node.skeleton else { continue }
            var crumbs: [(nodeId: String, title: String)] = []
            var cursor: InsightNode? = node
            while let current = cursor {
                crumbs.insert((current.id.uuidString, current.title), at: 0)
                cursor = current.parentId.flatMap { session.nodes[$0] }
            }
            let html = InsightHTMLTemplate.html(
                skeleton: skeleton, sectionStates: node.sectionStates, breadcrumbs: crumbs, libRefMode: .exportRelative, cache: cache
            )
            try? cache.writeNode(nodeId: id, html: html)
        }

        tasks.store(Task { @MainActor in
            do {
                let stagingURL = try await cache.archiveStagingDirectory()
                let exportRoot = try InsightArchiveExport.makeStagingCopy(from: stagingURL)
                defer { try? FileManager.default.removeItem(at: exportRoot) }
                try InsightArchiveExport.rewriteForStandalone(exportRoot: exportRoot, rootNodeId: rootNodeId, nodeChildMap: nodeChildMap)
                try await InsightArchiveExporter().bundle(stagingURL: exportRoot, to: destinationURL)
            } catch is CancellationError {
                AppLog.insight.notice("exportInsightArchive: cancelled")
            } catch InsightArchiveExporterError.cancelled {
                AppLog.insight.notice("exportInsightArchive: cancelled mid-zip")
            } catch {
                Self.alert("ZIP export failed", InsightSession.sanitizeForLog(error.localizedDescription), style: .warning)
            }
        }, for: "insight.export.\(session.id)")
    }

    private static func alert(_ title: String, _ message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
