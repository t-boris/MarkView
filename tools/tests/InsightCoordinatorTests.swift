import Foundation

// Recursive Insight of a window (AR-14 step 2): the shipping InsightCoordinator, InsightArchiveExport, InsightSession and
// InsightCache run over real folders and a real cache restored from a snapshot, with a stand-in window (`StubHost`) and page.
// No assistant is started, no panel or alert is shown.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

/// The open project as a feature reads it (`ProjectProviding`): a folder and no database.
@MainActor
final class StubProject: ProjectProviding {
    var root: URL?
    var aiProject: URL? { root }
    var linkedFolderURLs: [URL] { [] }
    var searchRoots: [URL] { root.map { [$0] } ?? [] }
    var database: SemanticDatabase? { nil }
    func relativePath(of url: URL) -> String { url.path }
    func markdownFiles(in folder: URL) -> [URL] { [] }
    func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
    func refreshFileTree() {}
    func containerRoot(for url: URL) -> URL? { root }
}

@MainActor
final class StubHost: InsightHost {
    var sessions: [InsightSession] = []
    var active: InsightSession?
    var events: [String] = []
    var insightSessions: [InsightSession] { sessions }
    var activeInsightSession: InsightSession? { active }
    func showInsightTab(_ session: InsightSession, placeholder: URL) {
        sessions.append(session)
        active = session
        events.append("show")
    }
    func removeInsightTab(sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        if active?.id == sessionID { active = nil }
        events.append("remove")
    }
}

@MainActor
final class StubPage: InsightPage {
    let host: StubHost
    init(host: StubHost) { self.host = host }
    func releaseInsightBlobs() { host.events.append("release") }
}

/// The cache's snapshot as `InsightSession` writes it (the shape of its private `RootSnapshot`).
struct SnapshotEntry: Codable {
    let nodeId: UUID
    let parentId: UUID?
    let level: Int
    let title: String
    let scope: NodeScope
    let skeleton: InsightSkeleton
    let sectionBuffers: [String: String]
    let childIds: [UUID]
}

struct Snapshot: Codable {
    let rootId: UUID
    let folderPath: String
    let createdAt: Date
    let skeleton: InsightSkeleton?
    let sectionBuffers: [String: String]?
    let nodes: [SnapshotEntry]?
}

func skeleton(title: String, topics: [String]) -> InsightSkeleton {
    InsightSkeleton(title: title, suggestedTheme: nil, sections: [
        InsightSection(id: "s1", type: .prose, title: "Overview", scopeHint: nil, metadata: [:],
                       deepDiveTopics: topics.enumerated().map {
                           InsightDeepDiveTopic(id: "t\($0.offset)", label: $0.element, hint: "hint \($0.element)", scopeHint: [])
                       })
    ])
}

func waitUntil(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("insight-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

func write(_ text: String, to url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

@MainActor
func run() async {
    print("=== Recursive Insight coordinator (AR-14 step 2) ===")

    // 1. File names of the archive.
    print("\n-- archive file names")
    check(InsightArchiveExport.sanitizeFilename("My docs/2026 (draft)") == "My_docs_2026_draft", "a folder name keeps strict ASCII letters, digits and underscores")
    check(InsightArchiveExport.sanitizeFilename("Мои заметки") == "insight", "a name with no ASCII letters falls back to `insight`")
    check(InsightArchiveExport.sanitizeFilename("__a__b__") == "a_b", "runs of underscores collapse and the ends are trimmed")
    let name = InsightArchiveExport.defaultFilename(folderName: "notes", date: Date(timeIntervalSince1970: 1_800_000_000))
    check(name.hasPrefix("notes_insight_") && name.hasSuffix("Z.zip") && !name.contains(":"), "the default archive name carries a colon-free ISO timestamp (\(name))")

    // The cache copies the vendored libraries from the bundle; the script puts the real ones next to the executable.
    let analysed = sandbox.appendingPathComponent("analysed", isDirectory: true)
    let first = analysed.appendingPathComponent("one.md"), second = analysed.appendingPathComponent("two.md")
    write("# one", to: first)
    write("# two", to: second)
    guard let cache = try? InsightCache(workspaceURL: analysed, sessionId: UUID()) else {
        check(false, "the cache opens on a real folder with the vendored libraries")
        return
    }
    check(true, "the cache opens on a real folder with the vendored libraries")

    // 2. The archive on a real cache: pages built by the shipping template, rewritten for a standalone browser.
    print("\n-- standalone archive")
    let rootId = InsightCache.deterministicRootUUID(forFolderPath: analysed.path)
    let childId = UUID()
    let rootNode = InsightNode(id: rootId, parentId: nil, level: 0, title: "Analysed", scope: .folderRoot)
    rootNode.skeleton = skeleton(title: "Analysed", topics: ["Auth flow", "Storage"])
    rootNode.children = [childId]
    let childNode = InsightNode(id: childId, parentId: rootId, level: 1, title: "Auth flow",
                                scope: .topic(label: "Auth flow", hint: "hint Auth flow", files: [first]))
    childNode.skeleton = skeleton(title: "Auth flow", topics: [])
    let nodes = [rootId: rootNode, childId: childNode]

    let map = InsightArchiveExport.childMap(nodes: nodes)
    check(map[rootId]?["s1"]?[0] == childId && map[rootId]?["s1"]?[1] == nil && map[childId] == nil,
          "the deep dive whose topic label is a child's title maps to that child; the other topic maps to none")

    for (id, node) in nodes {
        var crumbs: [(nodeId: String, title: String)] = []
        var cursor: InsightNode? = node
        while let current = cursor {
            crumbs.insert((current.id.uuidString, current.title), at: 0)
            cursor = current.parentId.flatMap { nodes[$0] }
        }
        let html = InsightSession.buildHTMLTemplate(skeleton: node.skeleton!, sectionStates: [:], breadcrumbs: crumbs,
                                                    libRefMode: .exportRelative, cache: cache)
        try? cache.writeNode(nodeId: id, html: html)
    }
    let liveRootBefore = (try? cache.readNode(nodeId: rootId)) ?? ""
    check(liveRootBefore.contains("<button class=\"deep-dive\"") && liveRootBefore.contains("\"../_assets/"),
          "the shipping template emits deep-dive buttons and `../_assets/` library references")

    do {
        let staging = try await cache.archiveStagingDirectory()
        let exportRoot = try InsightArchiveExport.makeStagingCopy(from: staging)
        defer { try? fm.removeItem(at: exportRoot) }
        check(exportRoot != staging && fm.fileExists(atPath: exportRoot.appendingPathComponent("nodes").path)
              && fm.fileExists(atPath: exportRoot.appendingPathComponent("_assets").path),
              "the staging copy is a new folder holding nodes/ and _assets/ at its root")
        try InsightArchiveExport.rewriteForStandalone(exportRoot: exportRoot, rootNodeId: rootId, nodeChildMap: map)
        let index = (try? String(contentsOf: exportRoot.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
        check(!index.isEmpty && !index.contains("\"../_assets/") && index.contains("\"_assets/"),
              "the root page is promoted to index.html with its library references one level shallower")
        check(index.contains("<a class=\"deep-dive\" href=\"nodes/\(childId.uuidString).html\""),
              "a deep dive that has a child page becomes a link to nodes/<child>.html")
        check(index.contains("<button class=\"deep-dive\" data-section-id=\"s1\" data-topic-index=\"1\""),
              "a deep dive without a child stays an inert button")
        let childPage = (try? String(contentsOf: exportRoot.appendingPathComponent("nodes/\(childId.uuidString).html"), encoding: .utf8)) ?? ""
        check(childPage.contains("<a class=\"crumb\" href=\"../index.html\">") && !childPage.contains("href=\"#"),
              "a node page's breadcrumb to the root points at ../index.html, and no `#` breadcrumb is left")
        let rootPage = (try? String(contentsOf: exportRoot.appendingPathComponent("nodes/\(rootId.uuidString).html"), encoding: .utf8)) ?? ""
        check(rootPage.contains("<a class=\"deep-dive\" href=\"\(childId.uuidString).html\""),
              "the root's copy under nodes/ links its child as a sibling")
        let liveRootAfter = (try? cache.readNode(nodeId: rootId)) ?? ""
        check(liveRootAfter == liveRootBefore, "rewriting the copy leaves the live cache untouched")
    } catch {
        check(false, "the archive staging and rewrite run without error: \(error)")
    }

    // 3. The coordinator over a session restored from that cache.
    print("\n-- coordinator")
    let snapshot = Snapshot(rootId: rootId, folderPath: analysed.path, createdAt: Date(), skeleton: nil, sectionBuffers: nil, nodes: [
        SnapshotEntry(nodeId: rootId, parentId: nil, level: 0, title: "Analysed", scope: .folderRoot,
                      skeleton: rootNode.skeleton!, sectionBuffers: ["s1": "<p>root</p>"], childIds: [childId]),
        SnapshotEntry(nodeId: childId, parentId: rootId, level: 1, title: "Auth flow",
                      scope: .topic(label: "Auth flow", hint: "hint Auth flow", files: [first]),
                      skeleton: childNode.skeleton!, sectionBuffers: ["s1": "<p>auth</p>"], childIds: [])
    ])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try? cache.writeSnapshotData(try! encoder.encode(snapshot))

    let session = InsightSession(folderURL: analysed, mdFiles: [first, second], graphRAG: nil, cache: cache)
    await session.generateRoot()
    check(session.nodes.count == 2 && session.currentNodeId == rootId && session.skeletonReady,
          "the session restores the root and its child from the cache snapshot")

    let host = StubHost()
    let project = StubProject()
    project.root = analysed
    host.sessions = [session]
    host.active = session
    let tasks = TaskBag()
    let coordinator = InsightCoordinator(host: host, project: project, tasks: tasks)
    let page = StubPage(host: host)
    coordinator.page = page
    let sid = session.id.uuidString

    coordinator.didRequestInsightDeepDive(sessionId: UUID().uuidString, sectionId: "s1", topicIndex: 0)
    coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "nope", topicIndex: 0)
    coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: 2)
    coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: -1)
    check(tasks.activeCount == 0 && session.currentNodeId == rootId,
          "a deep dive for a closed session, an unknown section or an index out of range starts nothing")

    coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: 0)
    check(tasks.contains(key: "insight.expand.\(session.id)"), "a valid deep dive runs on a task the window's bag owns")
    check(await waitUntil { session.currentNodeId == childId }, "the deep dive of a topic that already has a child shows that child, no assistant call")

    tasks.cancelAll()
    coordinator.didRequestInsightBreadcrumb(sessionId: sid, nodeId: "not-a-uuid")
    coordinator.didRequestInsightBreadcrumb(sessionId: sid, nodeId: UUID().uuidString)
    check(tasks.activeCount == 0 && session.currentNodeId == childId, "a breadcrumb with an invalid id or an id outside the manifest starts nothing")
    coordinator.didRequestInsightBreadcrumb(sessionId: sid, nodeId: rootId.uuidString)
    check(await waitUntil { session.currentNodeId == rootId }, "a breadcrumb to a node of the manifest navigates to it")

    tasks.cancelAll()
    coordinator.didRequestInsightUp()
    check(tasks.activeCount == 0 && session.currentNodeId == rootId, "↑ Up at the root does nothing")
    coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: 0)
    _ = await waitUntil { session.currentNodeId == childId }
    tasks.cancelAll()
    coordinator.didRequestInsightUp()
    check(await waitUntil { session.currentNodeId == rootId }, "↑ Up at a child navigates to its parent")

    host.active = nil
    tasks.cancelAll()
    coordinator.didRequestInsightUp()
    coordinator.didRequestInsightRegenerate()
    coordinator.didRequestInsightExploreAll(depth: 1)
    coordinator.didRequestInsightCustomDeepDive(topic: "x")
    coordinator.didRequestInsightRetrySection(sectionId: "s1")
    coordinator.didRequestInsightSave()
    check(tasks.activeCount == 0, "with no insight tab selected, none of the messages without a session id starts anything (and Save opens no panel)")
    host.active = session

    coordinator.cancelSessions()
    check(tasks.contains(key: "insight.cancel.\(session.id)"), "cancelling the sessions of a closing folder runs on an owned task")
    tasks.cancelAll()
    check(tasks.activeCount == 0, "the window's bag cancels everything the coordinator started")

    // Closing the tab: the page revokes its blob URLs first, the session ends, then the tab goes.
    coordinator.close(session)
    check(tasks.contains(key: "insight.close.\(session.id)"), "closing a tab runs on an owned task")
    check(await waitUntil { host.sessions.isEmpty }, "the tab is removed once the session has ended")
    check(host.events == ["release", "remove"], "the page releases its blobs before the tab is removed (events: \(host.events))")
    check((try? cache.readNode(nodeId: rootId)) == liveRootBefore, "closing keeps the cache, so reopening the folder's insight reuses it")
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await run()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}
try? fm.removeItem(at: sandbox)

print("\nInsight coordinator summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
