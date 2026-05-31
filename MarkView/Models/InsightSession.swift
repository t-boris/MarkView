import Foundation
import Combine

// MARK: - Supporting Types
//
// V2 Recursive Insight (tech-spec.md, Decision 1, 4, 10, 11). One InsightSession owns
// the in-memory tree of insight nodes for a single tab; the actual rendered HTML is
// composed deterministically by `writeFinalHTMLToCache(...)` (NOT by an iframe round-trip)
// and persisted via `InsightCache` (T3). The bridge layer (T7) subscribes to the
// `@Published` surface to drive the JS-side iframe srcdoc + per-section streaming.
//
// V1 marker parser (`---DEEP-DIVES---`), `streamCompletion`-only single-shot path, and
// right-pane deep-dive list are all deleted. v2 splits generation into:
//   Phase 1: `graphRAG.buildSkeleton(...)` returns a strict-schema `InsightSkeleton`
//            via Anthropic tool_use (single non-streaming call, T4 owns the call).
//   Phase 2: N parallel `providerClient.streamCompletion(...)` calls — one per section
//            in the skeleton — capped at 5 concurrent via `withThrowingTaskGroup`. Per
//            section `SectionState.buffer` accumulates the streamed HTML fragment.
//
// Types `InsightSkeleton`, `InsightSection`, `SectionType`, `InsightDeepDiveTopic`,
// `SectionState`, and the existing `AnyCodable` (defined in WebViewBridge.swift, reused
// per T4 decision) live in `InsightModels.swift` — DO NOT redeclare them here.

/// Scope of an InsightNode within the recursive tree.
/// `.folderRoot` is the top-level summary covering every `.md` file in the folder.
/// `.topic` is a deep-dive narrowed to a labelled subset (the model-emitted topic name,
/// hint, and the validated `.md` files matching the topic's `scope_hint`).
enum NodeScope: Codable {
    case folderRoot
    case topic(label: String, hint: String, files: [URL])

    // Manual Codable: associated values + URL serialise via path strings so the cached
    // node tree can round-trip cleanly (T8 Pre-deploy QA may exercise this).
    private enum CodingKeys: String, CodingKey { case kind, label, hint, files }
    private enum Kind: String, Codable { case folderRoot, topic }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folderRoot:
            try c.encode(Kind.folderRoot, forKey: .kind)
        case .topic(let label, let hint, let files):
            try c.encode(Kind.topic, forKey: .kind)
            try c.encode(label, forKey: .label)
            try c.encode(hint, forKey: .hint)
            try c.encode(files.map { $0.path }, forKey: .files)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .folderRoot:
            self = .folderRoot
        case .topic:
            let label = try c.decode(String.self, forKey: .label)
            let hint = try c.decode(String.self, forKey: .hint)
            let paths = try c.decode([String].self, forKey: .files)
            self = .topic(label: label, hint: hint, files: paths.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Convenience accessor for `phase1Skeleton` to feed `graphRAG.buildSkeleton`.
    var label: String? {
        switch self {
        case .folderRoot: return nil
        case .topic(let label, _, _): return label
        }
    }

    var hint: String? {
        switch self {
        case .folderRoot: return nil
        case .topic(_, let hint, _): return hint
        }
    }
}

/// Lightweight breadcrumb entry — UUIDs serialised as strings so the JS bridge can
/// pass them back as identifiers without re-decoding.
struct BreadcrumbEntry: Codable {
    let nodeId: String
    let title: String
}

/// Snapshot of the current insight view, consumed by the WebView bridge layer.
/// V2 shape: skeleton replaces v1 `markdown + deepDives` (the per-section iframe srcdoc
/// is rebuilt parent-side from `skeleton + section buffers`, see `writeFinalHTMLToCache`).
/// All identifiers serialised as strings to avoid JSON↔Swift UUID round-trip cost.
struct InsightViewSnapshot: Codable {
    let sessionId: String
    let nodeId: String
    let title: String
    let breadcrumbs: [BreadcrumbEntry]
    let skeleton: InsightSkeleton?
    let isStreaming: Bool
}

/// One node in the in-memory insight tree. Reference type because the tree is mutated
/// in place (per-section `buffer` accumulation, status transitions) and other parts of
/// `InsightSession` hold direct references via `nodes[id]`.
final class InsightNode: Identifiable, Codable {
    enum Status: String, Codable {
        case pending                // initialised, no LLM call yet
        case generatingSkeleton     // Phase 1 in flight
        case streamingContent       // Phase 2 in flight (one or more sections)
        case ready                  // all sections completed + cache written
        case failed                 // any phase errored or cap exceeded
    }

    let id: UUID
    let parentId: UUID?
    let level: Int
    let title: String
    let scope: NodeScope
    var skeleton: InsightSkeleton?
    /// Per-section streaming state. Keyed by `InsightSection.id`. Mutated only on
    /// `@MainActor`. Initialised lazily in `phase1Skeleton` once the skeleton is parsed.
    var sectionStates: [String: SectionState]
    var children: [UUID]
    var status: Status
    var generatedAt: Date?
    let model: String

    init(
        id: UUID = UUID(),
        parentId: UUID?,
        level: Int,
        title: String,
        scope: NodeScope,
        model: String = "claude-sonnet-4-6"
    ) {
        self.id = id
        self.parentId = parentId
        self.level = level
        self.title = title
        self.scope = scope
        self.skeleton = nil
        self.sectionStates = [:]
        self.children = []
        self.status = .pending
        self.generatedAt = nil
        self.model = model
    }

    /// Live byte total across all section buffers. Used by per-node + per-session caps
    /// (Decision 10 §7 / tech-spec "Resource caps"). UTF-8 byte count, not Swift `count`.
    var rawBufferForCap: Int {
        sectionStates.values.reduce(0) { $0 + $1.buffer.utf8.count }
    }
}

// MARK: - InsightSession

/// `@MainActor` session class owning the in-memory insight tree for one tab.
/// Drives a two-phase generation pipeline (Decision 1):
///   Phase 1 — single Anthropic tool_use call via `graphRAG.buildSkeleton(...)` returns
///             a strict-schema `InsightSkeleton`. Fallback skeleton (single prose section)
///             is produced inside T4 on schema violation.
///   Phase 2 — N parallel `streamCompletion(...)` calls, capped at 5 concurrent. Each
///             section's HTML fragment streams into `currentNodeSections[id].buffer`.
///
/// On Phase 2 completion the parent rebuilds the canonical HTML (skeleton + buffers +
/// chrome) deterministically and writes it via `InsightCache` for instant breadcrumb
/// back-navigation. NO iframe round-trip — that would breach the postMessage allowlist
/// (5 types per Decision 10 / tech-spec §"Disk cache write").
///
/// Lifecycle invariants (Decision 11):
///   - Every closure crossing an `await` boundary is `[weak self] in guard let self else { return }`.
///   - `activeTask` is the SOLE owner of the in-flight generation Task. Cancel-then-set-nil
///     semantics. Section-level tasks live only inside `withThrowingTaskGroup`.
///   - `cancel()` and `navigateTo(...)` are async — T8 closeTab awaits cancel before
///     `cache.cleanup()` to avoid races.
///   - API key never leaks into `lastError`: snapshot at init, redact in handleStreamError.
///   - All long-lived state mutations happen on `@MainActor`; off-main only the
///     SSE-byte-pump inside `streamCompletion` runs (it hops back via `Task { @MainActor }`).
@MainActor
final class InsightSession: ObservableObject, Identifiable {
    let id = UUID()

    // MARK: Inputs (immutable for session lifetime)

    let folderURL: URL
    let mdFiles: [URL]
    private let providerClient: AIProviderClient
    private let graphRAG: GraphRAG?

    /// Public-internal so `WorkspaceManager.closeTab` can call `session.cache.cleanup()`
    /// directly per the tech-spec ordered-close (Decision 11 §4) — kept non-private.
    let cache: InsightCache

    /// Snapshot of the api key at init-time, captured via `providerClient.apiKeySnapshot`
    /// (Decision 10 §6 — used only for redaction inside `handleStreamError`). Same
    /// limitation as v1: not refreshed on `AIProviderClient.updateAPIKey(_:)`. Mitigated
    /// by `streamCompletion`'s own `sanitize(_:)` defense-in-depth.
    private let apiKeySnapshot: String?

    // MARK: Published state — bridge layer (T7) subscribes via Combine

    /// UUID of the root node (always level 0). Set once, in `generateRoot()`.
    @Published private(set) var rootNodeId: UUID?

    /// UUID of the node the user is currently viewing. Driven by `navigateTo`, `up`,
    /// `expand`, and `generateRoot`. Bridge layer subscribes to forward iframe srcdoc
    /// reload on change.
    @Published private(set) var currentNodeId: UUID?

    /// In-memory node tree, keyed by id. Mutated on MainActor. Bridge layer reads via
    /// `currentNode()` / `breadcrumbs()` accessors — does NOT subscribe to `$nodes`
    /// (the dict-as-Published would over-emit on every byte of stream append).
    @Published private(set) var nodes: [UUID: InsightNode] = [:]

    /// Last user-visible error message. nil = no error. Bridge layer forwards to JS
    /// via `setInsightError` together with `lastErrorRetryable`.
    @Published private(set) var lastError: String?
    /// Whether a Retry button should appear. Non-retryable errors (parseError, noAPIKey,
    /// 4xx other than 429, retry rate limit, oversized buffer, cache write failure)
    /// set this to false (Decision 11 §3).
    @Published private(set) var lastErrorRetryable: Bool = true

    /// Per-section streaming state for the CURRENT node. Mirror of
    /// `nodes[currentNodeId].sectionStates` so the bridge can subscribe directly without
    /// peering into the dict. Updated atomically with the source-of-truth on every chunk.
    @Published private(set) var currentNodeSections: [String: SectionState] = [:]

    /// Skeleton of the current node, published separately (also stored in
    /// `nodes[currentNodeId].skeleton`) so the bridge can subscribe with `$skeleton`
    /// directly and forward to JS via `bridge.loadInsightSkeleton`.
    @Published private(set) var skeleton: InsightSkeleton?

    /// Phase-1 done flag — true once `phase1Skeleton` returns successfully. Triggers
    /// the bridge to render the iframe srcdoc placeholder grid.
    @Published private(set) var skeletonReady: Bool = false

    /// Phase-2 done flag — true once every section state is `.ready` AND the cache
    /// write succeeded. Bridge updates the status bar to "Ready".
    @Published private(set) var allSectionsReady: Bool = false

    /// Free-form status message for the bottom status bar
    /// (e.g. "Phase 1: building skeleton...", "Phase 2: 3/7 sections").
    @Published private(set) var statusMessage: String = ""

    /// Detected content type for this session (Phase 0 classifier output).
    /// Drives per-type skeleton + section prompt branches. Persisted in
    /// snapshot so cache restore preserves the choice without reclassifying.
    @Published private(set) var contentType: InsightContentType = .general

    /// Cached HTML for the current node, populated by `navigateTo` after a cache read
    /// hit. The bridge subscribes to forward as iframe srcdoc on the next frame.
    /// nil = no cached HTML (still streaming, or read miss).
    @Published private(set) var cachedNodeHTML: String?

    // MARK: v1-compat shims (consumed by EditorView.routeInsight + bridge stubs until T7)
    //
    // EditorView's Coordinator subscribes to v1's `$streamingBuffer` to forward delta
    // text to the now-stubbed bridge methods. Those subscriptions become no-ops because
    // the bridge methods are stubs (NSLog only) — but the Combine wiring must still
    // type-check. We expose `streamingBuffer` as a `@Published` empty string so the
    // EditorView subscription remains valid. T7 will rewrite EditorView to subscribe to
    // the v2 surface (`$skeleton`, `$currentNodeSections`, `$statusMessage`,
    // `$cachedNodeHTML`) and these shims will be removed.

    /// v1-compat shim. Always empty in v2. Removed by T7.
    @Published private(set) var streamingBuffer: String = ""

    /// v1-compat shim. Always false in v2 (status is encoded in node.status +
    /// statusMessage). Removed by T7.
    @Published private(set) var isStreaming: Bool = false

    // MARK: Internal state (not published)

    /// Single-owner of the in-flight generation Task. Cancel-then-set-nil discipline.
    /// Section-level tasks live only inside `withThrowingTaskGroup` and are cooperatively
    /// cancelled via `Task.checkCancellation` / `Task.isCancelled`.
    private var activeTask: Task<Void, Never>?

    /// Per-node sliding window of retry timestamps (Decision 11 §3 — 3 retries / 60 s).
    private var retryHistory: [UUID: [Date]] = [:]

    // MARK: Resource caps (Decision 10 §7 / tech-spec "Resource caps")

    private static let perNodeBufferCapBytes = 10 * 1024 * 1024     // 10 MB (raw section buffers)
    private static let perSessionBufferCapBytes = 50 * 1024 * 1024  // 50 MB (sum across nodes)
    private static let perFinalHTMLCapBytes = 2 * 1024 * 1024       // 2 MB (final cached HTML)
    private static let maxConcurrentSectionStreams = 5              // Decision 1
    private static let maxFilesPerDeepDive = 30                     // Decision 5
    private static let perFileTruncationCapBytes = 50 * 1024        // 50 KB (matches GraphRAG)

    // MARK: - Init

    init(
        folderURL: URL,
        mdFiles: [URL],
        providerClient: AIProviderClient,
        graphRAG: GraphRAG?,
        cache: InsightCache
    ) {
        self.folderURL = folderURL
        self.mdFiles = mdFiles
        self.providerClient = providerClient
        self.graphRAG = graphRAG
        self.cache = cache
        self.apiKeySnapshot = providerClient.apiKeySnapshot
    }

    /// v1-compat init — replaced by Task 7/8 once `WorkspaceManager.startRecursiveInsight`
    /// is updated to construct `InsightCache` and pass it explicitly. Builds a cache
    /// rooted under the system temp dir (NOT inside `folderURL` — avoids polluting the
    /// user's analyzed folder during the v1→v2 transition).
    ///
    /// `throws` is the cleanest signal: T8 will rewrite the call site to pass an
    /// explicit cache. Until then the v1 call site (`WorkspaceManager.startRecursiveInsight`)
    /// will need a `try?` wrap — handled by the WorkspaceManager v1 stub block in T6.
    convenience init(
        folderURL: URL,
        mdFiles: [URL],
        providerClient: AIProviderClient,
        graphRAG: GraphRAG?
    ) throws {
        // Cache lives under the system temp dir during the v1→v2 transition so we don't
        // accidentally start writing `.insight-cache/` into the user's folder before T8
        // wires up the proper lifecycle (closeTab cleanup ordering — Decision 11 §4).
        let placeholderId = UUID()
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("insight-v1-compat", isDirectory: true)
        let cache = try InsightCache(workspaceURL: cacheRoot, sessionId: placeholderId)
        self.init(
            folderURL: folderURL,
            mdFiles: mdFiles,
            providerClient: providerClient,
            graphRAG: graphRAG,
            cache: cache
        )
    }

    // MARK: - Public API: lifecycle

    /// Generate the root summary for the open folder. Idempotent: if a generation Task
    /// is already in-flight, returns immediately. Drives Phase 1 → Phase 2 → cache write.
    func generateRoot() async {
        // Idempotency.
        if activeTask != nil {
            NSLog("[Insight] generateRoot called while activeTask in flight — ignoring")
            return
        }

        // Defensive: empty folder shouldn't get here (T8 gates the entry point), but
        // surface a friendly error rather than spinning a useless pipeline.
        if mdFiles.isEmpty {
            lastError = "no markdown files in folder"
            lastErrorRetryable = false
            NSLog("[Insight] generateRoot called with empty mdFiles list")
            return
        }

        // Build root node with a DETERMINISTIC UUID derived from the folder
        // path so that closing and re-opening the insight on the same folder
        // produces the same root nodeId — and the persistent cache hit works
        // (otherwise every reopen would pick a fresh random UUID and the
        // cached snapshot/HTML would never be findable).
        let deterministicRootId = InsightCache.deterministicRootUUID(forFolderPath: folderURL.path)
        let root = InsightNode(
            id: deterministicRootId,
            parentId: nil,
            level: 0,
            title: folderURL.lastPathComponent,
            scope: .folderRoot
        )
        rootNodeId = root.id
        nodes[root.id] = root
        currentNodeId = root.id
        currentNodeSections = [:]
        skeleton = nil
        skeletonReady = false
        allSectionsReady = false
        cachedNodeHTML = nil
        lastError = nil
        lastErrorRetryable = true

        let nodeId = root.id

        // Try snapshot restore BEFORE kicking off the LLM pipeline. If a
        // snapshot exists for this folder (deterministic root UUID), repopulate
        // skeleton + sectionStates from disk and short-circuit Phase 1+2.
        if tryRestoreRootFromSnapshot(rootId: nodeId) {
            statusMessage = "✓ Restored from cache (use Regenerate to refresh)"
            return
        }

        statusMessage = "Phase 0: classifying content type…"
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Phase 0: classify content type (~1-2s LLM call). Persists
                // for the session — Phase 1 + Phase 2 prompts branch on it.
                if let rag = self.graphRAG {
                    let detected = await rag.classifyContent(folderURL: self.folderURL, mdFiles: self.mdFiles)
                    self.contentType = detected
                    self.statusMessage = "Phase 1: analyzing \(self.mdFiles.count) files (type: \(detected.displayLabel))…"
                } else {
                    self.statusMessage = "Phase 1: analyzing \(self.mdFiles.count) files…"
                }
                try Task.checkCancellation()
                let skel = try await self.phase1Skeleton(for: nodeId)
                try Task.checkCancellation()
                try await self.phase2StreamSections(for: nodeId, skeleton: skel)
                try Task.checkCancellation()
                try self.writeFinalHTMLToCache(nodeId: nodeId)
                self.writeSnapshotForRoot(nodeId: nodeId)
            } catch {
                self.handleStreamError(error, forNodeId: nodeId)
            }
            // Single-owner cleanup — clear the slot regardless of success/failure.
            self.activeTask = nil
        }
    }

    /// Retry one failed Phase-2 section on the current node. Resets just
    /// that section's buffer + status, re-runs streamCompletion for it,
    /// updates snapshot on success.
    func retrySection(sectionId: String) async {
        guard let curId = currentNodeId, let node = nodes[curId], let skel = node.skeleton else { return }
        guard let section = skel.sections.first(where: { $0.id == sectionId }) else { return }
        guard let rag = graphRAG else { return }
        // Reset this section so the EditorView sink resends content (and
        // the placeholder gets cleared).
        var s = node.sectionStates[sectionId] ?? SectionState()
        s.buffer = ""
        s.status = .streaming
        node.sectionStates[sectionId] = s
        if currentNodeId == curId {
            currentNodeSections = node.sectionStates
            statusMessage = "Retrying section: \(section.title ?? section.id)…"
        }
        // Build the prompt for this single section.
        let scopedFiles: [URL]
        switch node.scope {
        case .folderRoot: scopedFiles = mdFiles
        case .topic(_, _, let files): scopedFiles = files.isEmpty ? mdFiles : files
        }
        let prompts = rag.buildSectionPrompt(section: section, allFiles: scopedFiles, folderURL: folderURL, contentType: contentType)
        let nodeIdLocal = curId
        do {
            try await providerClient.streamCompletion(
                systemPrompt: prompts.systemPrompt,
                userMessage: prompts.userMessage,
                model: "claude-sonnet-4-6",
                maxTokens: 4096,
                onDelta: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.appendSectionDelta(sectionId: sectionId, chunk: chunk, forNodeId: nodeIdLocal)
                    }
                }
            )
            await markSectionReady(sectionId: sectionId, forNodeId: nodeIdLocal)
            // Refresh snapshot with new content for this section.
            try? writeFinalHTMLToCache(nodeId: nodeIdLocal)
            writeSnapshotForRoot(nodeId: nodeIdLocal)
            if currentNodeId == nodeIdLocal {
                statusMessage = "Section '\(section.title ?? section.id)' retried ✓"
            }
        } catch {
            NSLog("[Insight] retrySection failed: %@", Self.sanitizeForLog(error.localizedDescription))
            await markSectionFailed(sectionId: sectionId, forNodeId: nodeIdLocal)
            if currentNodeId == nodeIdLocal {
                lastError = "retry failed: \(error.localizedDescription)"
                lastErrorRetryable = true
            }
        }
    }

    /// User clicked "🤿×N Explore all". Recursively iterates EVERY deepDiveTopic
    /// on the current node's skeleton, depth `depth` (1 = just one level — the
    /// current page's topics; 2 = current + each child's topics; 3 = three
    /// levels). Sequential — one expand at a time, awaiting completion before
    /// the next. Reuses existing children for already-expanded topics.
    func expandAllTopicsOnCurrentNode(depth: Int = 1) async {
        guard let start = currentNode() else {
            lastError = "no current node to expand from"
            lastErrorRetryable = false
            return
        }
        let startId = start.id
        let actualDepth = max(1, min(3, depth))
        statusMessage = "Explore all (depth \(actualDepth)): starting…"
        let total = await recursiveExpand(rootNodeId: startId, depth: actualDepth, doneCounter: 0, totalCounter: nil)
        if currentNodeId != startId {
            await navigateTo(nodeId: startId)
        }
        statusMessage = "Explore all: done (\(total) nodes generated/reused at depth \(actualDepth))"
    }

    /// Sequential recursive expansion. Returns total expand calls made.
    /// `totalCounter` is the precomputed total topic count (if nil, computed
    /// once at top level for status display).
    private func recursiveExpand(rootNodeId: UUID, depth: Int, doneCounter: Int, totalCounter: Int?) async -> Int {
        var done = doneCounter
        guard depth >= 1, let node = nodes[rootNodeId], let skel = node.skeleton else { return done }
        // Collect (sectionId, topicIndex, label) pairs.
        var pairs: [(sectionId: String, topicIndex: Int, label: String)] = []
        for section in skel.sections {
            guard let topics = section.deepDiveTopics else { continue }
            for (idx, topic) in topics.enumerated() {
                pairs.append((section.id, idx, topic.label))
            }
        }
        if pairs.isEmpty { return done }
        // Compute total upfront only at top level (for accurate progress).
        let total: Int
        if let t = totalCounter { total = t } else { total = pairs.count } // approximate
        for pair in pairs {
            // Navigate to this expansion's PARENT before expanding (expand
            // creates child of currentNode).
            if currentNodeId != rootNodeId {
                await navigateTo(nodeId: rootNodeId)
            }
            done += 1
            statusMessage = "Explore all (\(done)/\(total ?? done)+ at depth \(depth)): \(pair.label)…"
            await expand(sectionId: pair.sectionId, topicIndex: pair.topicIndex)
            if let t = activeTask { _ = await t.value }
            // After expand, currentNode is the new child. If depth>1, recurse.
            if depth > 1, let childId = currentNodeId, childId != rootNodeId {
                done = await recursiveExpand(rootNodeId: childId, depth: depth - 1, doneCounter: done, totalCounter: totalCounter)
            }
        }
        return done
    }

    /// User-typed deep-dive on a custom topic (footer input). Creates a child
    /// of the CURRENT node scoped to all source files, with the user's topic
    /// as the label/hint. Same Phase 1+2 pipeline as `expand(...)`. Reuses
    /// existing child if a previous custom dive used the same topic.
    func expandCustom(topic: String) async {
        guard let parent = currentNode() else {
            lastError = "no current node to expand from"
            lastErrorRetryable = false
            return
        }
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Reuse existing child for the same custom topic (label + hint match).
        for childId in parent.children {
            guard let existing = nodes[childId] else { continue }
            if case .topic(let exLabel, let exHint, _) = existing.scope,
               exLabel == trimmed, exHint == trimmed {
                NSLog("[Insight] expandCustom: reusing existing child for topic '%@'", Self.sanitizeForLog(trimmed))
                await navigateTo(nodeId: childId)
                return
            }
        }

        // Cancel any in-flight Task before mutating shared state.
        activeTask?.cancel()
        activeTask = nil

        let child = InsightNode(
            parentId: parent.id,
            level: parent.level + 1,
            title: trimmed,
            scope: .topic(label: trimmed, hint: trimmed, files: [])  // empty files = use all
        )
        nodes[child.id] = child
        parent.children.append(child.id)
        currentNodeId = child.id
        currentNodeSections = [:]
        skeleton = nil
        skeletonReady = false
        allSectionsReady = false
        cachedNodeHTML = nil
        lastError = nil
        lastErrorRetryable = true
        statusMessage = "Phase 1: analyzing \(mdFiles.count) files for custom dive..."

        enforceSessionMemoryCap()

        let nodeId = child.id
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let skel = try await self.phase1Skeleton(for: nodeId)
                try Task.checkCancellation()
                try await self.phase2StreamSections(for: nodeId, skeleton: skel)
                try Task.checkCancellation()
                try self.writeFinalHTMLToCache(nodeId: nodeId)
                self.writeSnapshotForRoot(nodeId: nodeId)
            } catch {
                self.handleStreamError(error, forNodeId: nodeId)
            }
            self.activeTask = nil
        }
    }

    /// Force regeneration: wipe snapshot, reset state, kick off fresh Phase 1+2.
    /// Called from WorkspaceManager when user clicks the ⟳ Regenerate button.
    /// Behaviour depends on what the user is currently looking at:
    ///   - At ROOT: regenerate the entire tree (children would no longer match
    ///     the new root skeleton's deep-dive topics anyway, so wipe everything
    ///     and run Phase 1+2 fresh).
    ///   - At a deep-dive CHILD: regenerate ONLY that child. The root and
    ///     siblings stay intact — user explicitly clicked Regenerate while
    ///     viewing the child, so they want THAT child redone, not the whole
    ///     tree thrown away.
    func regenerateRoot() async {
        guard let curId = currentNodeId, let curNode = nodes[curId] else {
            // No current node — full reset path.
            await fullResetAndGenerate()
            return
        }
        if curNode.parentId == nil {
            // At root → wipe + regenerate everything.
            await fullResetAndGenerate()
            return
        }
        // At child → re-run only this node's Phase 1+2.
        await regenerateNode(curId)
    }

    /// Full tree reset + fresh generateRoot. Wipes snapshot AND every cached
    /// node HTML on disk so no stale entries linger.
    private func fullResetAndGenerate() async {
        await cancel()
        cache.deleteSnapshot()
        // Delete every node's cached HTML file before dropping in-memory map.
        for id in nodes.keys { cache.deleteNode(nodeId: id) }
        nodes.removeAll()
        rootNodeId = nil
        currentNodeId = nil
        currentNodeSections = [:]
        skeleton = nil
        skeletonReady = false
        allSectionsReady = false
        cachedNodeHTML = nil
        lastError = nil
        lastErrorRetryable = true
        await generateRoot()
    }

    /// Re-run Phase 1+2 for one node. Also drops ALL descendants of this node
    /// from the in-memory tree — old children were derived from the previous
    /// skeleton's deepDive topics, which may no longer match the new skeleton.
    /// Snapshot is rewritten by writeSnapshotForRoot after Phase 2 completes
    /// (it iterates `nodes` so dropped descendants naturally fall out of the
    /// snapshot too). Root + siblings of this node stay intact.
    private func regenerateNode(_ nodeId: UUID) async {
        await cancel()
        guard let node = nodes[nodeId] else { return }
        // Recursively collect descendant ids (DFS).
        var toRemove: [UUID] = []
        var stack: [UUID] = node.children
        while let id = stack.popLast() {
            toRemove.append(id)
            if let n = nodes[id] { stack.append(contentsOf: n.children) }
        }
        for id in toRemove {
            nodes.removeValue(forKey: id)
            // Best-effort delete of the on-disk cached HTML for this node.
            cache.deleteNode(nodeId: id)
        }
        // Also delete THIS node's cached HTML — it'll be regenerated.
        cache.deleteNode(nodeId: nodeId)
        // Reset this node so generation re-fills it.
        node.children = []
        node.skeleton = nil
        node.sectionStates = [:]
        node.status = .pending
        if currentNodeId == nodeId {
            skeleton = nil
            skeletonReady = false
            allSectionsReady = false
            currentNodeSections = [:]
            cachedNodeHTML = nil
            lastError = nil
            lastErrorRetryable = true
            statusMessage = "Phase 1: analyzing files for this node..."
        }
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let skel = try await self.phase1Skeleton(for: nodeId)
                try Task.checkCancellation()
                try await self.phase2StreamSections(for: nodeId, skeleton: skel)
                try Task.checkCancellation()
                try self.writeFinalHTMLToCache(nodeId: nodeId)
                self.writeSnapshotForRoot(nodeId: nodeId)
            } catch {
                self.handleStreamError(error, forNodeId: nodeId)
            }
            self.activeTask = nil
        }
    }

    /// Per-node persisted snapshot (root or any deep-dive child).
    private struct NodeSnapshotEntry: Codable {
        let nodeId: UUID
        let parentId: UUID?
        let level: Int
        let title: String
        let scope: NodeScope
        let skeleton: InsightSkeleton
        let sectionBuffers: [String: String]
        let childIds: [UUID]
    }

    /// Whole-tree snapshot — root + all generated deep-dives. Restored on
    /// reopen so deep-dive buttons reuse cached children instead of re-running
    /// Phase 1+2.
    private struct RootSnapshot: Codable {
        let rootId: UUID
        let folderPath: String
        let createdAt: Date
        // Legacy fields kept for forward compatibility (older snapshots only had these).
        let skeleton: InsightSkeleton?
        let sectionBuffers: [String: String]?
        // New: full tree.
        let nodes: [NodeSnapshotEntry]?
    }

    /// Try to restore the root node + ALL cached deep-dive children from
    /// `<cacheRoot>/snapshot.json`. Populates `nodes` map so subsequent
    /// `expand(...)` calls find existing children (matched by topic
    /// label+hint) and `navigateTo(...)` succeeds for any saved nodeId.
    /// Returns true on success.
    @MainActor
    private func tryRestoreRootFromSnapshot(rootId: UUID) -> Bool {
        guard let data = cache.readSnapshotData() else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snap = try? decoder.decode(RootSnapshot.self, from: data) else {
            NSLog("[Insight] snapshot decode failed — falling back to fresh generation")
            return false
        }
        guard snap.rootId == rootId else {
            NSLog("[Insight] snapshot rootId mismatch — folder path collision? regenerating")
            return false
        }

        // Prefer the new full-tree snapshot. Fall back to legacy root-only
        // snapshot for forward compatibility.
        let entries: [NodeSnapshotEntry]
        if let ns = snap.nodes, !ns.isEmpty {
            entries = ns
        } else if let skel = snap.skeleton, let bufs = snap.sectionBuffers {
            // Synthesise a single root entry from the legacy fields.
            entries = [NodeSnapshotEntry(
                nodeId: rootId,
                parentId: nil,
                level: 0,
                title: folderURL.lastPathComponent,
                scope: .folderRoot,
                skeleton: skel,
                sectionBuffers: bufs,
                childIds: []
            )]
        } else {
            return false
        }

        // Rebuild every InsightNode from the snapshot. The pre-existing root
        // node (created in generateRoot before this call) is overwritten.
        for entry in entries {
            let node = InsightNode(
                id: entry.nodeId,
                parentId: entry.parentId,
                level: entry.level,
                title: entry.title,
                scope: entry.scope
            )
            node.skeleton = entry.skeleton
            var states: [String: SectionState] = [:]
            for section in entry.skeleton.sections {
                var s = SectionState()
                s.buffer = entry.sectionBuffers[section.id] ?? ""
                s.status = s.buffer.isEmpty ? .pending : .ready
                states[section.id] = s
            }
            node.sectionStates = states
            node.status = .ready
            node.children = entry.childIds
            nodes[entry.nodeId] = node
        }

        // Make root the current view.
        guard let rootNode = nodes[rootId], let rootSkel = rootNode.skeleton else { return false }
        currentNodeId = rootId
        skeleton = rootSkel
        skeletonReady = true
        currentNodeSections = rootNode.sectionStates
        allSectionsReady = true
        cachedNodeHTML = (try? cache.readNode(nodeId: rootId))
        NSLog("[Insight] snapshot restored: %d nodes total", entries.count)
        return true
    }

    /// Write the WHOLE node tree (root + all generated deep-dive children)
    /// to `cache.snapshot.json` after any node finishes Phase 2. Snapshot
    /// is rewritten in full each time — small (~100 KB per node) so the
    /// rewrite cost is negligible, and the alternative (incremental patch)
    /// is more complex than warranted. Failures swallowed (snapshot is a
    /// UX nicety, not a correctness invariant).
    private nonisolated func writeSnapshotForRoot(nodeId: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let rootId = self.rootNodeId else { return }
            var entries: [NodeSnapshotEntry] = []
            for (id, node) in self.nodes {
                guard let skel = node.skeleton else { continue }
                var bufs: [String: String] = [:]
                for (sid, st) in node.sectionStates { bufs[sid] = st.buffer }
                // Skip nodes that have a skeleton but NO content at all —
                // they're useless until generation completes.
                let totalContent = bufs.values.reduce(0) { $0 + $1.count }
                if totalContent == 0 { continue }
                entries.append(NodeSnapshotEntry(
                    nodeId: id,
                    parentId: node.parentId,
                    level: node.level,
                    title: node.title,
                    scope: node.scope,
                    skeleton: skel,
                    sectionBuffers: bufs,
                    childIds: node.children
                ))
            }
            let snap = RootSnapshot(
                rootId: rootId,
                folderPath: self.folderURL.path,
                createdAt: Date(),
                skeleton: nil,
                sectionBuffers: nil,
                nodes: entries
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(snap)
                try self.cache.writeSnapshotData(data)
                NSLog("[Insight] snapshot saved (%d nodes, %d bytes)", entries.count, data.count)
            } catch {
                NSLog("[Insight] snapshot save failed: %@", String(describing: error))
            }
        }
    }

    /// User clicked an inline 🤿 deep-dive control. Cancels any in-flight generation,
    /// creates a child node scoped by the topic, and runs the same Phase 1 → Phase 2 →
    /// cache-write pipeline.
    ///
    /// Bounds-check is defense-in-depth — T5 parent JS validates `topicIndex` against
    /// the section's `deepDiveTopics.length`, but we re-check here so a compromised
    /// JS context cannot panic the session via an out-of-range index.
    func expand(sectionId: String, topicIndex: Int) async {
        guard let parent = currentNode() else {
            lastError = "no current node to expand from"
            lastErrorRetryable = false
            return
        }
        guard let parentSkeleton = parent.skeleton else {
            lastError = "current node skeleton not yet available"
            lastErrorRetryable = true
            return
        }
        guard let section = parentSkeleton.sections.first(where: { $0.id == sectionId }) else {
            NSLog("[Insight] expand: unknown sectionId %@", Self.sanitizeForLog(sectionId))
            lastError = "unknown section"
            lastErrorRetryable = false
            return
        }
        guard let topics = section.deepDiveTopics,
              topicIndex >= 0,
              topicIndex < topics.count else {
            NSLog("[Insight] expand: topicIndex %d out of bounds (topics: %d)",
                  topicIndex, section.deepDiveTopics?.count ?? 0)
            lastError = "deep-dive index out of bounds"
            lastErrorRetryable = false
            return
        }
        let topic = topics[topicIndex]

        // Reuse existing child for the same deep-dive topic if one was
        // already generated under THIS parent (matched by topic title +
        // hint, since the topic id is internal to the skeleton). Saves the
        // ~60 s Phase 1 LLM call when the user re-opens a previously
        // explored deep-dive — the existing child node still carries its
        // skeleton and per-section buffers in memory; navigateTo restores
        // them directly.
        for childId in parent.children {
            guard let existing = nodes[childId] else { continue }
            if case .topic(let exLabel, let exHint, _) = existing.scope,
               exLabel == topic.label, exHint == topic.hint {
                NSLog("[Insight] expand: reusing existing child for topic '%@' (no regen)",
                      Self.sanitizeForLog(topic.label))
                await navigateTo(nodeId: childId)
                return
            }
        }

        // Validate scope_hint paths now (Decision 10 §6). Cap at 30 files (Decision 5).
        var validated = validateScopeHint(topic.scopeHint)
        if validated.count > Self.maxFilesPerDeepDive {
            validated = Array(validated.prefix(Self.maxFilesPerDeepDive))
            NSLog("[Insight] expand: scope_hint capped at %d files", Self.maxFilesPerDeepDive)
        }

        // Defense-in-depth: cancel any prior active task before creating new node so a
        // double-click or race never leaves two pipelines mutating shared state.
        activeTask?.cancel()
        activeTask = nil

        let child = InsightNode(
            parentId: parent.id,
            level: parent.level + 1,
            title: topic.label,
            scope: .topic(label: topic.label, hint: topic.hint, files: validated)
        )
        nodes[child.id] = child
        parent.children.append(child.id)
        currentNodeId = child.id
        currentNodeSections = [:]
        skeleton = nil
        skeletonReady = false
        allSectionsReady = false
        cachedNodeHTML = nil
        lastError = nil
        lastErrorRetryable = true
        let scopedCount = validated.isEmpty ? mdFiles.count : validated.count
        statusMessage = "Phase 1: analyzing \(scopedCount) files..."

        // Memory cap check after node creation (Decision 10 §7).
        enforceSessionMemoryCap()

        let nodeId = child.id
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let skel = try await self.phase1Skeleton(for: nodeId)
                try Task.checkCancellation()
                try await self.phase2StreamSections(for: nodeId, skeleton: skel)
                try Task.checkCancellation()
                try self.writeFinalHTMLToCache(nodeId: nodeId)
                self.writeSnapshotForRoot(nodeId: nodeId)
            } catch {
                self.handleStreamError(error, forNodeId: nodeId)
            }
            self.activeTask = nil
        }
    }

    /// Pure UI navigation — switch to an existing in-tree node. Reads cached HTML from
    /// disk if available (Decision 4). Cancels any in-flight generation (the user
    /// explicitly switched away). Async because cache.readNode is filesystem I/O.
    func navigateTo(nodeId: UUID) async {
        guard nodes[nodeId] != nil else {
            lastError = "node not found"
            lastErrorRetryable = false
            return
        }

        // Cancel pending stream — user is no longer watching it. Buffers preserve.
        activeTask?.cancel()
        activeTask = nil

        currentNodeId = nodeId
        skeleton = nodes[nodeId]?.skeleton
        skeletonReady = (skeleton != nil)
        currentNodeSections = nodes[nodeId]?.sectionStates ?? [:]
        allSectionsReady = (nodes[nodeId]?.status == .ready)
        lastError = nil
        lastErrorRetryable = true

        // Cache read — best-effort. Miss is OK (fresh node mid-stream, or cache cleaned).
        cachedNodeHTML = (try? cache.readNode(nodeId: nodeId))
        // Status message reflects whether we actually loaded HTML from disk cache.
        statusMessage = (cachedNodeHTML != nil) ? "Loaded from cache" : ""
    }

    /// Equivalent to clicking the parent breadcrumb. No-op when already at root.
    func up() async {
        guard let parentId = currentNode()?.parentId else { return }
        await navigateTo(nodeId: parentId)
    }

    /// Cancel the in-flight generation Task (if any). Async — awaits the Task's exit
    /// so callers (T8 closeTab) can serialise `cache.cleanup()` after parallel section
    /// tasks have observed `Task.isCancelled` (Decision 11 §4 ordering).
    func cancel() async {
        activeTask?.cancel()
        // Await the Task's natural exit. Task<Void, Never>.value never throws.
        if let task = activeTask {
            _ = await task.value
        }
        activeTask = nil
    }

    /// Re-run the current node's pipeline. Throttle: 3 retries / 60 s sliding window
    /// per node (Decision 11 §3). 4th attempt is rejected with `lastErrorRetryable=false`.
    /// Resets the current node's state in-place (no new node id).
    func retryCurrent() async {
        guard let node = currentNode() else { return }
        let nodeId = node.id

        // Throttle.
        let now = Date()
        var window = (retryHistory[nodeId] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if window.count >= 3 {
            lastError = "retry rate limit (3/60s)"
            lastErrorRetryable = false
            retryHistory[nodeId] = window
            return
        }
        window.append(now)
        retryHistory[nodeId] = window

        // Reset current-node state in place.
        node.skeleton = nil
        node.sectionStates = [:]
        node.status = .pending
        currentNodeSections = [:]
        skeleton = nil
        skeletonReady = false
        allSectionsReady = false
        cachedNodeHTML = nil
        lastError = nil
        lastErrorRetryable = true
        statusMessage = "Retrying current node (attempt \(retryHistory[nodeId]?.count ?? 1)/3)..."

        // Cancel any prior active task and re-run pipeline for SAME node id.
        activeTask?.cancel()
        activeTask = nil

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let skel = try await self.phase1Skeleton(for: nodeId)
                try Task.checkCancellation()
                try await self.phase2StreamSections(for: nodeId, skeleton: skel)
                try Task.checkCancellation()
                try self.writeFinalHTMLToCache(nodeId: nodeId)
                self.writeSnapshotForRoot(nodeId: nodeId)
                // On natural completion, clear retry window (Decision 11 §3).
                self.clearRetryHistory(for: nodeId)
            } catch {
                self.handleStreamError(error, forNodeId: nodeId)
            }
            self.activeTask = nil
        }
    }

    // MARK: - Read accessors

    func currentNode() -> InsightNode? {
        return currentNodeId.flatMap { nodes[$0] }
    }

    /// Walk parentId chain from current up to root, return [root, ..., current].
    func breadcrumbs() -> [InsightNode] {
        var chain: [InsightNode] = []
        var cursor = currentNode()
        while let node = cursor {
            chain.append(node)
            if let parentId = node.parentId {
                cursor = nodes[parentId]
            } else {
                cursor = nil
            }
        }
        return chain.reversed()
    }

    /// Snapshot of current view state for bridge layer to forward to JS.
    func snapshot() -> InsightViewSnapshot {
        let crumbs = breadcrumbs().map {
            BreadcrumbEntry(nodeId: $0.id.uuidString, title: $0.title)
        }
        let cur = currentNode()
        let isStreaming = (cur?.status == .generatingSkeleton)
            || (cur?.status == .streamingContent)
        return InsightViewSnapshot(
            sessionId: id.uuidString,
            nodeId: cur?.id.uuidString ?? "",
            title: cur?.title ?? "",
            breadcrumbs: crumbs,
            skeleton: cur?.skeleton,
            isStreaming: isStreaming
        )
    }

    // MARK: - Phase 1: skeleton via tool_use (delegated to GraphRAG)

    /// Delegates to `graphRAG.buildSkeleton(...)` — T4 owns the entire phase 1 surface
    /// (prompt composition + toolCall invocation + parse + fallback skeleton on
    /// schema violation). This method only:
    ///   - flips the node status,
    ///   - calls T4's helper,
    ///   - validates section ids + deep-dive topic ids unique within skeleton,
    ///   - publishes the parsed skeleton + initialises per-section state.
    private func phase1Skeleton(for nodeId: UUID) async throws -> InsightSkeleton {
        guard let node = nodes[nodeId] else {
            throw AIProviderError.streamingError("phase1Skeleton: node \(nodeId) evicted")
        }
        node.status = .generatingSkeleton

        guard let rag = graphRAG else {
            throw AIProviderError.streamingError("GraphRAG required for insight generation")
        }

        // For deep-dive topic nodes, narrow mdFiles to the topic's validated scope.
        // If the validated scope ends up with zero readable files (LLM emitted
        // hallucinated paths that all fail file-exists check), fall back to
        // the full session mdFiles instead of failing the deep-dive.
        var scopedFiles: [URL]
        let scopeKind: String
        switch node.scope {
        case .folderRoot:
            scopedFiles = mdFiles
            scopeKind = "folderRoot"
        case .topic(let label, _, let files):
            // Only keep paths that actually exist on disk RIGHT NOW.
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            scopedFiles = existing.isEmpty ? mdFiles : existing
            scopeKind = "topic('\(label.prefix(40))') hint=\(files.count) existing=\(existing.count) effective=\(scopedFiles.count)"
        }
        WebViewBridge.logInsightDiag("phase1Skeleton START node=\(nodeId.uuidString.prefix(8)) scope=\(scopeKind) mdFiles=\(mdFiles.count) scopedFiles=\(scopedFiles.count) firstFile=\(scopedFiles.first?.path.prefix(80) ?? "(none)")")

        try Task.checkCancellation()
        let parsed = try await rag.buildSkeleton(
            folderURL: folderURL,
            mdFiles: scopedFiles,
            scopeLabel: node.scope.label,
            scopeHint: node.scope.hint,
            contentType: contentType
        )
        try Task.checkCancellation()

        // Defense-in-depth: validate section id uniqueness + deep-dive id uniqueness.
        // T4's tool_use schema doesn't enforce this server-side. On collision we keep
        // the first occurrence and log; we do NOT throw because that would degrade UX.
        var seenSectionIds = Set<String>()
        var validatedSections: [InsightSection] = []
        for section in parsed.sections {
            if seenSectionIds.contains(section.id) {
                NSLog("[Insight] phase1: duplicate section id '%@' — dropping", Self.sanitizeForLog(section.id))
                continue
            }
            seenSectionIds.insert(section.id)
            // Validate per-section scopeHint (drop invalid paths, keep section).
            // Skip if scopeHint is nil/empty — section uses all files.
            if let hint = section.scopeHint, !hint.isEmpty {
                let validURLs = validateScopeHint(hint)
                if validURLs.count != hint.count {
                    NSLog("[Insight] phase1: section '%@' had %d invalid scope_hint paths (kept %d)",
                          Self.sanitizeForLog(section.id), hint.count - validURLs.count, validURLs.count)
                }
                // We don't mutate scopeHint here — T4's `buildSectionPrompt` re-validates
                // against folderURL on each call, so leaving the (possibly noisy) original
                // is fine. Logging the rejection rate is the deliverable.
            }
            // Deep-dive topic id uniqueness within section.
            if let topics = section.deepDiveTopics {
                var seenTopicIds = Set<String>()
                for topic in topics {
                    if seenTopicIds.contains(topic.id) {
                        NSLog("[Insight] phase1: section '%@' duplicate topic id '%@'",
                              Self.sanitizeForLog(section.id), Self.sanitizeForLog(topic.id))
                    }
                    seenTopicIds.insert(topic.id)
                }
            }
            validatedSections.append(section)
        }

        let validatedSkeleton = InsightSkeleton(
            title: parsed.title,
            suggestedTheme: parsed.suggestedTheme,
            sections: validatedSections
        )

        // Publish.
        node.skeleton = validatedSkeleton
        if currentNodeId == nodeId {
            self.skeleton = validatedSkeleton
            self.skeletonReady = true
        }

        // Initialise per-section state.
        var initialStates: [String: SectionState] = [:]
        for section in validatedSections {
            initialStates[section.id] = SectionState()
        }
        node.sectionStates = initialStates
        if currentNodeId == nodeId {
            self.currentNodeSections = initialStates
            // Phase 1 success — concrete completion message before phase 2 fires.
            self.statusMessage = "Phase 1: built skeleton (\(validatedSections.count) sections) ✓"
        }

        return validatedSkeleton
    }

    // MARK: - Phase 2: parallel streaming sections (cap=5)

    /// Schedule all sections in parallel with a hard cap of 5 in-flight at any moment
    /// (Decision 1). Each section issues its own `streamCompletion(...)`; deltas hop to
    /// `@MainActor` to mutate `sectionStates[id].buffer`.
    ///
    /// Per-section error isolation (Wave 6 audit T9 #4 fix / tech-spec Risks row): each
    /// section task wraps its body in `do/catch` so a per-section throw (e.g. an
    /// Anthropic 429 on one section) marks ONLY that section `.failed` and does NOT
    /// cancel sibling tasks. Cooperative cancellation still works — both because
    /// `Task.isCancelled` is observed inside `streamCompletion` between SSE lines AND
    /// because outer-scope cancellation propagates to children of `withThrowingTaskGroup`.
    private func phase2StreamSections(
        for nodeId: UUID,
        skeleton: InsightSkeleton
    ) async throws {
        guard let node = nodes[nodeId] else {
            throw AIProviderError.streamingError("phase2: node \(nodeId) evicted")
        }
        node.status = .streamingContent

        guard let rag = graphRAG else {
            throw AIProviderError.streamingError("GraphRAG required for section streaming")
        }

        // Snapshot file list + folder URL at scope-resolution time so the off-actor
        // streaming closures don't repeatedly hop back for them.
        let scopedFiles: [URL]
        switch node.scope {
        case .folderRoot:
            scopedFiles = mdFiles
        case .topic(_, _, let files):
            scopedFiles = files.isEmpty ? mdFiles : files
        }

        // Pre-build all per-section prompts on the MainActor (rag is @MainActor).
        // buildSectionPrompt is pure + side-effect-free; we materialise the (system,
        // user) pair once here and capture the resulting Sendable strings into the
        // off-actor section tasks. Avoids hopping back to MainActor inside each task.
        var preparedPrompts: [(section: InsightSection, systemPrompt: String, userMessage: String)] = []
        preparedPrompts.reserveCapacity(skeleton.sections.count)
        for section in skeleton.sections {
            let prompts = rag.buildSectionPrompt(
                section: section,
                allFiles: scopedFiles,
                folderURL: folderURL,
                contentType: contentType
            )
            preparedPrompts.append((section: section, systemPrompt: prompts.systemPrompt, userMessage: prompts.userMessage))
        }

        // Status update — phase 2 about to start streaming N sections.
        if currentNodeId == nodeId {
            self.statusMessage = "Phase 2: 0/\(skeleton.sections.count) sections complete..."
        }

        // Use a non-throwing task group: per-section errors are caught INSIDE each
        // task body (Wave 6 audit T9 #4) so a single failing section cannot cancel
        // siblings. The outer `try Task.checkCancellation()` at the gate is the only
        // throw site that should propagate (user explicitly cancelled the session).
        await withTaskGroup(of: Void.self) { group in
            var iter = preparedPrompts.makeIterator()
            var inFlight = 0
            let cap = Self.maxConcurrentSectionStreams

            // Gated scheduling: launch up to `cap`, then await one per new launch.
            while let prepared = iter.next() {
                if Task.isCancelled { break }
                if inFlight >= cap {
                    _ = await group.next()
                    inFlight -= 1
                }
                let sectionId = prepared.section.id
                let systemPrompt = prepared.systemPrompt
                let userMessage = prepared.userMessage
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        try Task.checkCancellation()
                        // Stream. onDelta hops back to MainActor for state mutation.
                        try await self.providerClient.streamCompletion(
                            systemPrompt: systemPrompt,
                            userMessage: userMessage,
                            model: "claude-sonnet-4-6",
                            maxTokens: 4096,
                            onDelta: { [weak self] chunk in
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    self.appendSectionDelta(
                                        sectionId: sectionId,
                                        chunk: chunk,
                                        forNodeId: nodeId
                                    )
                                }
                            }
                        )
                        // Stream finished cleanly. Mark ready on main.
                        await self.markSectionReady(sectionId: sectionId, forNodeId: nodeId)
                    } catch is CancellationError {
                        // Outer cancellation — silent unwind, do NOT mark as failed.
                        return
                    } catch {
                        // Per-section error (rate limit, network blip, parse). Mark
                        // ONLY this section as failed; siblings keep streaming.
                        // Sanitised log for audit-trail integrity (T10 SEC-001).
                        NSLog("[Insight] phase2 section %@ failed: %@",
                              Self.sanitizeForLog(sectionId),
                              Self.sanitizeForLog(error.localizedDescription))
                        await self.markSectionFailed(sectionId: sectionId, forNodeId: nodeId)
                    }
                }
                inFlight += 1
            }

            // Drain remaining tasks. Non-throwing — `waitForAll()` here cannot
            // propagate per-section errors because each task swallowed its own.
            await group.waitForAll()
        }
        try Task.checkCancellation()

        // All section tasks unwound (each either marked .ready or .failed). Per Wave 6
        // audit T9 #4 the node is .ready as long as AT LEAST one section streamed
        // successfully — this matches the tech-spec Risks expectation that a single
        // rate-limited section should not invalidate the whole node. Sections marked
        // .failed surface in the per-section UI; the user can Retry the full node.
        let readyCount = node.sectionStates.values.filter { $0.status == .ready }.count
        let totalCount = node.sectionStates.count
        node.status = .ready
        node.generatedAt = Date()
        if currentNodeId == nodeId {
            self.allSectionsReady = true
            self.statusMessage = readyCount == totalCount
                ? "✓ Complete (\(totalCount)/\(totalCount) sections, cached for instant back-nav)"
                : "Ready (\(readyCount)/\(totalCount) sections — some failed)"
        }
    }

    /// Append a streaming chunk into the named node's section buffer. Always writes to
    /// the source-of-truth (`nodes[forNodeId].sectionStates[sectionId].buffer`) even if
    /// the user has navigated away — the buffer keeps growing for the eventual cache
    /// write. The visible `currentNodeSections` mirror is updated only when the chunk's
    /// node IS the currently-viewed one.
    ///
    /// Enforces:
    ///   - Per-node 10 MB cap → cancel + status `.failed` + `lastError = "response too large"`.
    ///   - Per-session 50 MB cap → eviction of oldest non-current-path nodes.
    private func appendSectionDelta(sectionId: String, chunk: String, forNodeId: UUID) {
        // Post-cancel guard: between the off-main `onDelta` invocation and the @MainActor
        // hop, the activeTask may have been cancelled OR the node may already be `.failed`.
        if Task.isCancelled { return }
        guard let node = nodes[forNodeId] else { return }
        guard node.status == .streamingContent else { return }

        var state = node.sectionStates[sectionId] ?? SectionState()
        if state.status == .pending {
            state.status = .streaming
        }
        state.buffer += chunk
        node.sectionStates[sectionId] = state

        // Per-node cap (Decision 10 §7).
        if node.rawBufferForCap > Self.perNodeBufferCapBytes {
            activeTask?.cancel()
            activeTask = nil
            node.status = .failed
            lastError = "response too large (>10 MB)"
            lastErrorRetryable = false
            statusMessage = ""
            NSLog("[Insight] per-node 10 MB cap exceeded; stream cancelled")
            return
        }

        // Mirror to the published @MainActor map. Status-bar updates are driven by
        // `markSectionReady` / `markSectionFailed` (per-section granularity) — NOT
        // per-chunk, to avoid excessive Combine emission. The streaming-hint in
        // `markSectionReady` reflects which section is currently in flight.
        if currentNodeId == forNodeId {
            currentNodeSections[sectionId] = state
        }

        // Per-session cap (Decision 10 §7).
        enforceSessionMemoryCap()
    }

    /// Section-stream completed successfully — flip the section's status to `.ready`
    /// and update the status bar with completed/total + an optional hint at any
    /// section that is still streaming (for user-visible "what's happening now").
    private func markSectionReady(sectionId: String, forNodeId: UUID) {
        guard let node = nodes[forNodeId] else { return }
        if var state = node.sectionStates[sectionId] {
            state.status = .ready
            node.sectionStates[sectionId] = state
        }
        if currentNodeId == forNodeId {
            if var state = currentNodeSections[sectionId] {
                state.status = .ready
                currentNodeSections[sectionId] = state
            }
            let completed = currentNodeSections.values.filter { $0.status == .ready }.count
            let total = currentNode()?.skeleton?.sections.count ?? node.sectionStates.count
            // Find any currently-streaming section's title for context.
            var streamingHint = ""
            if let skel = currentNode()?.skeleton {
                if let streamingSection = skel.sections.first(where: {
                    currentNodeSections[$0.id]?.status == .streaming
                }), let title = streamingSection.title {
                    streamingHint = " (\(title) streaming...)"
                }
            }
            statusMessage = "Phase 2: \(completed)/\(total) sections complete\(streamingHint)"
        }
    }

    /// Section-stream errored — flip the section's status to `.failed` (mirror of
    /// `markSectionReady`). Used by the per-section error-isolation path in
    /// `phase2StreamSections` (Wave 6 audit T9 #4 fix). Preserves any partial
    /// buffer for diagnostics; siblings keep streaming unchanged.
    private func markSectionFailed(sectionId: String, forNodeId: UUID) {
        guard let node = nodes[forNodeId] else { return }
        if var state = node.sectionStates[sectionId] {
            state.status = .failed
            node.sectionStates[sectionId] = state
        }
        if currentNodeId == forNodeId {
            if var state = currentNodeSections[sectionId] {
                state.status = .failed
                currentNodeSections[sectionId] = state
            }
            let completed = currentNodeSections.values.filter { $0.status == .ready }.count
            let total = currentNode()?.skeleton?.sections.count ?? node.sectionStates.count
            let failedCount = currentNodeSections.values.filter { $0.status == .failed }.count
            statusMessage = "Phase 2: \(completed)/\(total) complete, \(failedCount) failed"
        }
    }

    // MARK: - Cache write (deterministic HTML rebuild — no iframe round-trip)

    /// Rebuild the canonical HTML for the node from `(skeleton + section buffers + chrome)`
    /// and write atomically to `InsightCache`. NEVER reads from the iframe — the parent
    /// is the single source of truth (Decision 10 / tech-spec §"Disk cache write").
    ///
    /// Per Decision 10:
    ///   - All LLM-controlled skeleton string fields (title, section.title, deep-dive
    ///     label/hint, scopeHint paths displayed) are HTML-escaped via `escapeForHTML`.
    ///   - Section buffer HTML is preserved verbatim — already inside the iframe trust
    ///     boundary; iframe sandbox isolates execution.
    ///   - Per-node 2 MB final-HTML cap (tech-spec acceptance criterion). Exceeding sets
    ///     node `.failed` and emits a non-retryable error.
    private func writeFinalHTMLToCache(nodeId: UUID) throws {
        guard let node = nodes[nodeId] else {
            throw InsightSessionError.cacheWriteFailed("node evicted before cache write")
        }
        guard let skel = node.skeleton else {
            throw InsightSessionError.cacheWriteFailed("skeleton missing for node \(nodeId)")
        }

        // Build crumbs for chrome — escaped.
        let crumbs = breadcrumbs().map { ($0.id.uuidString, $0.title) }

        let html = Self.buildHTMLTemplate(
            skeleton: skel,
            sectionStates: node.sectionStates,
            breadcrumbs: crumbs,
            libRefMode: .exportRelative,
            cache: cache
        )

        // Per-node final HTML cap (tech-spec acceptance "Per-node final HTML cap 2 MB").
        if html.utf8.count > Self.perFinalHTMLCapBytes {
            node.status = .failed
            if currentNodeId == nodeId {
                lastError = "final HTML too large (>2 MB)"
                lastErrorRetryable = false
                statusMessage = ""
            }
            throw InsightSessionError.cacheWriteFailed("final HTML exceeds 2 MB cap")
        }

        // Write atomically.
        do {
            try cache.writeNode(nodeId: nodeId, html: html)
        } catch {
            throw InsightSessionError.cacheWriteFailed("writeNode failed: \(error.localizedDescription)")
        }

        // Update manifest atomically — best-effort load (first write seeds it).
        var manifest: InsightManifest
        if let loaded = try? cache.loadManifest() {
            manifest = loaded
        } else {
            manifest = InsightManifest(
                sessionId: id,
                folderName: folderURL.lastPathComponent,
                createdAt: Date(),
                nodes: []
            )
        }
        // Append (or replace) this node's manifest entry.
        manifest.nodes.removeAll { $0.nodeId == nodeId }
        manifest.nodes.append(
            InsightManifest.NodeManifestEntry(
                nodeId: nodeId,
                parentId: node.parentId,
                title: node.title,
                level: node.level,
                createdAt: node.generatedAt ?? Date()
            )
        )
        do {
            try cache.updateManifest(manifest)
        } catch {
            throw InsightSessionError.cacheWriteFailed("updateManifest failed: \(error.localizedDescription)")
        }

        // Cache the rebuilt HTML for instant local switching without re-reading from disk.
        if currentNodeId == nodeId {
            cachedNodeHTML = html
        }
    }

    // MARK: - HTML template (single source of truth for runtime + cache)

    /// Lib reference mode for the rebuilt HTML.
    /// - `runtimeBlobs(libBlobURLs:)` — passes blob: URLs from parent (T7's lazy materialisation).
    /// - `exportRelative` — references `../_assets/<lib>` for ZIP export portability (T8).
    /// Currently `writeFinalHTMLToCache` always uses `exportRelative` because cache also
    /// serves as the ZIP-export source (Decision 4: `_assets/` lives inside session dir).
    enum LibRefMode {
        case runtimeBlobs(libBlobURLs: [String: String])
        case exportRelative
    }

    /// Deterministic HTML composition. Reproducible: identical (skeleton, sectionStates,
    /// breadcrumbs) input → byte-identical output. NO Date interpolation, NO new UUIDs —
    /// only known-good fields from the in-memory tree.
    ///
    /// `cache` is optional and only consulted in `.exportRelative` mode to resolve
    /// vendored lib filenames dynamically from `_assets/` (Wave 6 audit T9 #1 fix).
    /// In `.runtimeBlobs(...)` mode the caller supplies the blob URLs directly so no
    /// disk lookup is required.
    static func buildHTMLTemplate(
        skeleton: InsightSkeleton,
        sectionStates: [String: SectionState],
        breadcrumbs: [(nodeId: String, title: String)],
        libRefMode: LibRefMode,
        cache: InsightCache? = nil
    ) -> String {
        let escapedTitle = escapeForHTML(skeleton.title)

        // Breadcrumb chrome (parent frame — uses textContent in JS, but we still escape
        // because the static HTML is rendered as HTML at file-open / ZIP-export time).
        var breadcrumbHTML = ""
        for (idx, crumb) in breadcrumbs.enumerated() {
            let label = escapeForHTML(crumb.title)
            let isLast = (idx == breadcrumbs.count - 1)
            if isLast {
                breadcrumbHTML += "<span class=\"crumb crumb-active\">\(label)</span>"
            } else {
                let nodeIdAttr = escapeForHTML(crumb.nodeId)
                breadcrumbHTML += "<a class=\"crumb\" href=\"#\(nodeIdAttr)\">\(label)</a>"
                breadcrumbHTML += "<span class=\"crumb-sep\"> / </span>"
            }
        }

        // Per-section HTML — buffer interpolated VERBATIM (already inside iframe trust
        // boundary). Section title + id + scopeHint paths displayed are escaped.
        var sectionsHTML = ""
        for section in skeleton.sections {
            let buffer = sectionStates[section.id]?.buffer ?? ""
            let sectionId = escapeForHTML(section.id)
            let title = section.title.map { "<h2>\(escapeForHTML($0))</h2>" } ?? ""

            // Inline 🤿 deep-dive controls. Each control posts `insightDeepDiveClicked`
            // with sectionId+topicIndex via the iframe → parent → bridge chain (T7).
            var topicsHTML = ""
            if let topics = section.deepDiveTopics, !topics.isEmpty {
                topicsHTML += "<div class=\"deep-dives\">"
                for (idx, topic) in topics.enumerated() {
                    let label = escapeForHTML(topic.label)
                    let hint = escapeForHTML(topic.hint)
                    topicsHTML += """
                    <button class="deep-dive" data-section-id="\(sectionId)" data-topic-index="\(idx)" title="\(hint)">🤿 \(label)</button>
                    """
                }
                topicsHTML += "</div>"
            }

            sectionsHTML += """
            <section class="insight-section" data-section-id="\(sectionId)" data-section-type="\(section.type.rawValue)">
              \(title)
              <div class="section-body">\(buffer)</div>
              \(topicsHTML)
            </section>
            """
        }

        // Lib references (Decision 5).
        var libRefs = ""
        switch libRefMode {
        case .runtimeBlobs(let blobs):
            // Each lib blob: <script src="blob:...">. Iframe sandbox null-origin can load these.
            for (name, blobURL) in blobs.sorted(by: { $0.key < $1.key }) {
                let safe = escapeForHTML(blobURL)
                if name.hasSuffix(".css") {
                    libRefs += "<link rel=\"stylesheet\" href=\"\(safe)\">\n"
                } else {
                    libRefs += "<script src=\"\(safe)\"></script>\n"
                }
            }
        case .exportRelative:
            // Export-friendly relative refs to `_assets/`. Filenames are resolved
            // dynamically from the cache's `_assets/` directory so version bumps in
            // `Resources/Editor/vendor/` (e.g. `chart-4.4.9.min.js` →
            // `chart-5.x.min.js`) do not desync with a hard-coded list (Wave 6
            // audit T9 #1 fix). Each entry is a (prefix, extension) pair; the
            // shortest-name match wins for determinism. Output order is sorted by
            // resolved filename so the byte-for-byte reproducibility contract holds.
            let prefixes: [(prefix: String, ext: String)] = [
                ("prism", "css"),
                ("prism", "js"),
                ("mermaid", "js"),
                ("chart", "js"),
                ("katex", "css"),
                ("katex", "js"),
                ("auto-render", "js"),
                ("markdown-it", "js")
            ]
            var resolved: [(filename: String, kind: String)] = []
            for entry in prefixes {
                if let url = cache?.vendoredLibURL(matching: entry.prefix, extension: entry.ext) {
                    resolved.append((filename: url.lastPathComponent, kind: entry.ext))
                }
            }
            for entry in resolved.sorted(by: { $0.filename < $1.filename }) {
                if entry.kind == "css" {
                    libRefs += "<link rel=\"stylesheet\" href=\"../_assets/\(entry.filename)\">\n"
                } else {
                    libRefs += "<script src=\"../_assets/\(entry.filename)\"></script>\n"
                }
            }
        }

        // CSP for the cached HTML (Wave 6 audit T9 #3 fix). Aligned with the iframe
        // srcdoc CSP (Decision 10 §3 / index.html:2827) but adapted for the cached /
        // exported context: scripts and styles load from `'self'` (the cache root or
        // the unzipped export) instead of `blob:`. Webfonts and images come from
        // `'self'` + `data:` only — no wildcard CDNs. Matches the iframe's
        // defense-in-depth posture (`default-src 'none'`, `connect-src 'none'`,
        // `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'`).
        let csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"

        // Mirror the iframe srcdoc's section/hero/table/callout/timeline/
        // cards-grid/mermaid/chart styling so the exported standalone site
        // looks the same as the in-app view. Plus minimal mermaid/chart
        // bootstrap scripts (libs are loaded via libRefs above).
        let inlineCSS = """
        html, body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; background: #fff; color: #1e1e1e; }
        body { padding: 16px 24px; }
        header.insight-breadcrumbs { padding: 8px 0 12px; border-bottom: 1px solid #e0e0e0; margin-bottom: 16px; font-size: 13px; }
        .crumb { color: #2563eb; text-decoration: none; padding: 2px 6px; border-radius: 3px; }
        .crumb:hover { background: #f0f4ff; }
        .crumb-active { color: #1e1e1e; font-weight: 600; }
        .crumb-sep { color: #999; padding: 0 2px; }
        section.insight-section { margin-bottom: 28px; padding-bottom: 20px; border-bottom: 1px solid #e0e0e0; }
        section.insight-section:last-of-type { border-bottom: none; }
        section.insight-section h2 { font-size: 16px; font-weight: 600; margin: 0 0 8px; color: #2a2a2a; }
        .section-body { font-size: 14px; line-height: 1.6; }
        .section-body img { max-width: 100%; height: auto; }
        section[data-section-type="hero"] h2 { display: none; }
        section[data-section-type="hero"] .section-body h1 { font-size: 22px; line-height: 1.2; margin: 0 0 6px; color: #1e1e1e; font-weight: 700; }
        section[data-section-type="hero"] .section-body h1 + p { font-size: 14px; line-height: 1.5; margin: 0 0 4px; color: #4a4a4a; }
        section[data-section-type="hero"] .section-body p { margin: 4px 0; }
        section[data-section-type="hero"] .section-body { font-size: 13px; }
        .mermaid { max-height: 520px; overflow: hidden; cursor: zoom-in; }
        .mermaid svg { max-width: 100%; height: auto; max-height: 520px; display: block; margin: 0 auto; }
        section[data-section-type="chartJsChart"] .section-body { position: relative; height: 360px; max-height: 50vh; overflow: hidden; }
        section[data-section-type="chartJsChart"] canvas { max-height: 360px !important; max-width: 100% !important; display: block; }
        .section-body table { width: 100%; border-collapse: collapse; margin: 6px 0 12px; font-size: 13px; }
        .section-body th, .section-body td { padding: 6px 10px; border: 1px solid #e0e0e0; text-align: left; vertical-align: top; }
        .section-body th { background: #f5f7fb; font-weight: 600; color: #1e1e1e; }
        .section-body tbody tr:nth-child(odd) td { background: #fafafa; }
        .cards-grid { display: grid !important; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; align-items: stretch; }
        .cards-grid .card, .cards-grid > article { background: #f8f9fb; border: 1px solid #e0e0e0; border-radius: 6px; padding: 12px 14px; min-width: 0; display: flex; flex-direction: column; }
        .cards-grid .card h3, .cards-grid > article h3 { margin: 0 0 6px; font-size: 13px; font-weight: 600; color: #1e1e1e; }
        .cards-grid .card p, .cards-grid > article p { margin: 4px 0; font-size: 12px; line-height: 1.45; }
        .cards-grid .card .meta, .cards-grid > article .meta { font-size: 11px; color: #6b7280; }
        .callout { padding: 10px 14px; border-left: 4px solid #6b7280; background: #f5f7fb; margin: 8px 0; border-radius: 4px; }
        .callout.callout-info { border-color: #3b82f6; background: #eff6ff; }
        .callout.callout-warn { border-color: #f59e0b; background: #fffbeb; }
        .callout.callout-danger { border-color: #ef4444; background: #fef2f2; }
        .callout.callout-tip { border-color: #10b981; background: #ecfdf5; }
        .timeline { list-style: none; padding: 0; margin: 8px 0; border-left: 2px solid #d4d4d4; }
        .timeline li { position: relative; padding: 4px 0 8px 16px; }
        .timeline li::before { content: ''; position: absolute; left: -6px; top: 8px; width: 10px; height: 10px; background: #569cd6; border-radius: 50%; }
        .timeline time { display: inline-block; font-weight: 600; color: #1e1e1e; margin-right: 6px; }
        .deep-dives { margin-top: 10px; display: flex; flex-wrap: wrap; gap: 6px; }
        .deep-dive { background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px; padding: 4px 10px; font-size: 12px; cursor: pointer; font-family: inherit; text-decoration: none; }
        .deep-dive:hover { background: #e8e8e8; border-color: #909090; }
        pre { background: #f6f8fa; padding: 10px; border-radius: 4px; overflow-x: auto; font-size: 12px; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .inferred { color: #b45309; font-style: italic; border-bottom: 1px dashed #b45309; }
        .mermaid, .section-body canvas, .section-body img { cursor: zoom-in; }
        #lb { position: fixed; inset: 0; z-index: 10000; background: rgba(0,0,0,0.88); display: none; align-items: center; justify-content: center; padding: 32px; box-sizing: border-box; }
        #lb.on { display: flex; }
        #lb .lb-stage { position: relative; width: 100%; height: 100%; overflow: auto; display: flex; align-items: center; justify-content: center; }
        #lb .lb-content { transform-origin: center center; transition: transform 0.18s ease; background: #fff; padding: 16px; border-radius: 6px; cursor: grab; user-select: none; }
        #lb .lb-content svg, #lb .lb-content img, #lb .lb-content canvas { display: block; max-width: none; max-height: none; }
        #lb .lb-bar { position: absolute; top: 16px; right: 16px; display: flex; gap: 6px; background: #fff; padding: 6px 10px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }
        #lb .lb-bar button { background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px; padding: 6px 12px; font-size: 14px; cursor: pointer; font-family: inherit; min-width: 36px; }
        #lb .lb-bar button:hover { background: #2563eb; color: #fff; border-color: #2563eb; }
        #lb .lb-bar .lb-pct { display: inline-flex; align-items: center; padding: 0 6px; font-size: 13px; color: #666; min-width: 50px; justify-content: center; }
        """

        // Bootstrap script — initialises mermaid + chart, wires lightbox click-to-zoom.
        let bootstrap = """
        <script>
        (function() {
            try {
                if (typeof mermaid !== 'undefined') {
                    mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', flowchart: { htmlLabels: true } });
                    var mNodes = document.querySelectorAll('.mermaid, pre code.language-mermaid, pre.mermaid');
                    for (var i = 0; i < mNodes.length; i++) {
                        var n = mNodes[i];
                        if (n.tagName !== 'DIV') {
                            var pre = (n.tagName === 'CODE') ? n.parentElement : n;
                            if (!pre) continue;
                            var src = (n.textContent || '').trim().replace(/<br\\s*\\/>/gi, '<br>');
                            var d = document.createElement('div');
                            d.className = 'mermaid';
                            d.textContent = src;
                            pre.replaceWith(d);
                        }
                    }
                    try { mermaid.run({ nodes: document.querySelectorAll('.mermaid'), suppressErrors: true }); } catch (e) {}
                }
                if (typeof Chart !== 'undefined') {
                    var canvases = document.querySelectorAll('canvas[data-chart], canvas[data-chart-config]');
                    for (var j = 0; j < canvases.length; j++) {
                        var cv = canvases[j];
                        var s = cv.getAttribute('data-chart') || cv.getAttribute('data-chart-config') || '';
                        if (!s) continue;
                        var clean = s.replace(/"function"\\s*:\\s*"function[\\s\\S]*?"\\s*\\}/g, '"_stripped":true}');
                        try { var cfg = JSON.parse(clean); new Chart(cv, cfg); } catch (e) {}
                    }
                }
                // Lightbox.
                var lb = null, lbContent = null, lbZoom = 1, lbPanX = 0, lbPanY = 0;
                var dragging = false, dsx = 0, dsy = 0, dix = 0, diy = 0;
                function applyTransform() { if (lbContent) lbContent.style.transform = 'translate(' + lbPanX + 'px,' + lbPanY + 'px) scale(' + lbZoom + ')'; }
                function setZoom(z) { lbZoom = Math.max(0.25, Math.min(8, z)); applyTransform(); var p = lb && lb.querySelector('.lb-pct'); if (p) p.textContent = Math.round(lbZoom * 100) + '%'; }
                function close() { if (lb) lb.classList.remove('on'); if (lbContent) lbContent.innerHTML = ''; lbPanX = lbPanY = 0; lbZoom = 1; }
                function ensure() {
                    if (lb) return;
                    lb = document.createElement('div'); lb.id = 'lb';
                    lb.innerHTML = '<div class="lb-stage"><div class="lb-content"></div></div>' +
                        '<div class="lb-bar">' +
                        '<button class="lb-out">−</button><span class="lb-pct">100%</span>' +
                        '<button class="lb-in">+</button><button class="lb-reset">1:1</button>' +
                        '<button class="lb-close">✕</button></div>';
                    document.body.appendChild(lb);
                    lbContent = lb.querySelector('.lb-content');
                    lb.querySelector('.lb-in').onclick = function(e) { e.stopPropagation(); setZoom(lbZoom * 1.25); };
                    lb.querySelector('.lb-out').onclick = function(e) { e.stopPropagation(); setZoom(lbZoom / 1.25); };
                    lb.querySelector('.lb-reset').onclick = function(e) { e.stopPropagation(); lbPanX = lbPanY = 0; setZoom(1); };
                    lb.querySelector('.lb-close').onclick = function(e) { e.stopPropagation(); close(); };
                    lb.addEventListener('click', function(ev) { if (ev.target === lb || (ev.target.classList && ev.target.classList.contains('lb-stage'))) close(); });
                    document.addEventListener('keydown', function(ev) {
                        if (!lb.classList.contains('on')) return;
                        if (ev.key === 'Escape') close();
                        else if (ev.key === '+' || ev.key === '=') setZoom(lbZoom * 1.25);
                        else if (ev.key === '-' || ev.key === '_') setZoom(lbZoom / 1.25);
                        else if (ev.key === '0' || ev.key === '1') { lbPanX = lbPanY = 0; setZoom(1); }
                    });
                    lb.addEventListener('wheel', function(ev) {
                        if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); setZoom(lbZoom * (ev.deltaY < 0 ? 1.1 : 0.9)); }
                    }, { passive: false });
                    lbContent.addEventListener('mousedown', function(ev) {
                        if (ev.target.closest('.lb-bar')) return;
                        dragging = true; dsx = ev.clientX; dsy = ev.clientY; dix = lbPanX; diy = lbPanY;
                        lbContent.style.transition = 'none'; lbContent.style.cursor = 'grabbing';
                        ev.preventDefault();
                    });
                    document.addEventListener('mousemove', function(ev) {
                        if (!dragging) return;
                        lbPanX = dix + (ev.clientX - dsx); lbPanY = diy + (ev.clientY - dsy);
                        applyTransform();
                    });
                    document.addEventListener('mouseup', function() { if (!dragging) return; dragging = false; if (lbContent) { lbContent.style.transition = ''; lbContent.style.cursor = ''; } });
                }
                function open(el) {
                    ensure();
                    lbContent.innerHTML = '';
                    if (el.classList && el.classList.contains('mermaid')) { var inner = el.querySelector('svg'); if (inner) el = inner; }
                    var clone;
                    if (el.tagName && el.tagName.toUpperCase() === 'CANVAS') {
                        try { var img = document.createElement('img'); img.src = el.toDataURL('image/png'); img.style.width = el.width + 'px'; img.style.height = el.height + 'px'; clone = img; }
                        catch (_) { clone = el.cloneNode(true); }
                    } else if (el.tagName && el.tagName.toLowerCase() === 'svg') {
                        try {
                            var ser = new XMLSerializer();
                            var svgStr = ser.serializeToString(el);
                            var box = el.viewBox && el.viewBox.baseVal;
                            var w = (box && box.width) ? box.width : (el.getBoundingClientRect().width || 800);
                            var h = (box && box.height) ? box.height : (el.getBoundingClientRect().height || 600);
                            var holder = document.createElement('div');
                            holder.style.cssText = 'width:' + (w * 2) + 'px; height:' + (h * 2) + 'px;';
                            holder.innerHTML = svgStr;
                            var ns = holder.querySelector('svg');
                            if (ns) { ns.setAttribute('width', '100%'); ns.setAttribute('height', '100%'); ns.style.maxWidth = 'none'; ns.style.maxHeight = 'none'; }
                            clone = holder;
                        } catch (_) { clone = el.cloneNode(true); }
                    } else { clone = el.cloneNode(true); }
                    lbContent.appendChild(clone);
                    lbPanX = lbPanY = 0; setZoom(1);
                    lb.classList.add('on');
                }
                document.addEventListener('click', function(ev) {
                    var t = ev.target;
                    if (!t || typeof t.closest !== 'function') return;
                    var pick = t.closest('.mermaid, .section-body canvas, .section-body img');
                    if (!pick) return;
                    if (t.closest('.deep-dive, .crumb, .lb-bar, #lb')) return;
                    ev.preventDefault(); ev.stopPropagation();
                    try { open(pick); } catch (_) {}
                }, false);
            } catch (e) {}
        })();
        </script>
        """

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <title>\(escapedTitle)</title>
        <style>\(inlineCSS)</style>
        \(libRefs)
        </head>
        <body>
        <header class="insight-chrome insight-breadcrumbs">\(breadcrumbHTML)</header>
        <main class="insight-content">
        \(sectionsHTML)
        </main>
        <footer class="insight-chrome insight-status"></footer>
        \(bootstrap)
        </body>
        </html>
        """
    }

    /// HTML-escape utility (Decision 10). Applied to ALL LLM-controlled strings BEFORE
    /// interpolation into the rebuilt HTML. The five canonical replacements + single-quote
    /// (covers attribute and text contexts).
    static func escapeForHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Strip `\r`, `\n`, and `\0` control bytes and truncate to 64 chars. Mirrors
    /// `WorkspaceManager.sanitizeForLog` (line 1507) and `WebViewBridge.sanitizeForLog`.
    /// Applied to every LLM-controlled string interpolated into `NSLog(...)` so a
    /// poisoned scope_hint / section id / topic id cannot forge audit-log lines via
    /// embedded newlines (Wave 6 audit T10 SEC-001 / CWE-117 fix).
    ///
    /// `nonisolated` because callers include the off-actor `group.addTask` closure in
    /// `phase2StreamSections` — pure-fn over a value-type `String`, no actor state
    /// touched, so safe to invoke from any isolation context.
    nonisolated static func sanitizeForLog(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: "[\\r\\n\\0]",
            with: "_",
            options: .regularExpression
        )
        return String(stripped.prefix(64))
    }

    // MARK: - Error handling (pattern table preserved from v1 round-2 fix 62b8bff)

    /// Pattern-match `error` against `AIProviderError` cases (Decision 11 §3 + v1 fix
    /// 62b8bff). Sanitises the api key out of the message before storing.
    /// Preserves section buffers — user sees partial content + Retry button.
    private func handleStreamError(_ error: Error, forNodeId: UUID) {
        // Cancellation is silent (normal lifecycle — user closed tab, retried, etc.).
        if error is CancellationError {
            return
        }
        if Task.isCancelled {
            return
        }

        var message: String
        var retryable: Bool

        if let providerError = error as? AIProviderError {
            switch providerError {
            case .noAPIKey:
                message = "No API key configured"
                retryable = false
            case .invalidResponse:
                message = "Invalid API response — retry available"
                retryable = true
            case .httpError(let code, _):
                if code == 429 || (500..<600).contains(code) {
                    message = "API error \(code): retry available"
                    retryable = true
                } else {
                    message = "API error \(code)"
                    retryable = false
                }
            case .parseError(let msg):
                message = "Parse failure: \(msg)"
                retryable = false
            case .streamingError(let msg):
                message = "Streaming failed: \(msg)"
                retryable = true
            }
        } else if let cacheErr = error as? InsightSessionError {
            switch cacheErr {
            case .cacheWriteFailed(let reason):
                message = "Cache write failed: \(reason)"
                retryable = false
            }
        } else {
            message = error.localizedDescription
            retryable = true
        }

        // API key redaction (Decision 10 §6).
        if let key = apiKeySnapshot, !key.isEmpty, message.contains(key) {
            message = message.replacingOccurrences(of: key, with: "<redacted>")
        }

        // Mark the actual erroring node failed (preserve from v1 finding #1). If the node
        // was evicted between stream-start and error landing, log + continue.
        if let erroringNode = nodes[forNodeId] {
            erroringNode.status = .failed
        } else {
            NSLog("[Insight] handleStreamError: node \(forNodeId) was evicted before error landed")
        }

        // Only mutate visible UI state when the user is still looking at the erroring node.
        if currentNodeId == forNodeId {
            lastError = message
            lastErrorRetryable = retryable
            statusMessage = ""
        }
        // Buffers preserved (Decision 11 §3) — partial content + Retry button.
    }

    // MARK: - Retry history

    private func clearRetryHistory(for nodeId: UUID) {
        retryHistory[nodeId] = []
    }

    // MARK: - Resource caps (per-session eviction)

    /// Sum every node's section buffers; if over 50 MB, evict the oldest non-current-path
    /// nodes until back under cap. Eviction order: by `generatedAt` ascending; ties broken
    /// by `level` descending. Removed nodes are unlinked from parents' children lists.
    private func enforceSessionMemoryCap() {
        let total = nodes.values.reduce(0) { $0 + $1.rawBufferForCap }
        guard total > Self.perSessionBufferCapBytes else { return }

        // Protected set: every node along the current breadcrumbs (root → current).
        let protectedIds = Set(breadcrumbs().map { $0.id })

        let candidates = nodes.values.filter { !protectedIds.contains($0.id) }
        let sorted = candidates.sorted { (a, b) in
            let ad = a.generatedAt ?? .distantPast
            let bd = b.generatedAt ?? .distantPast
            if ad != bd { return ad < bd }
            return a.level > b.level
        }

        var running = total
        for victim in sorted {
            if running <= Self.perSessionBufferCapBytes { break }
            // Unlink from parent's children list.
            if let pid = victim.parentId, let parent = nodes[pid] {
                parent.children.removeAll { $0 == victim.id }
            }
            running -= victim.rawBufferForCap
            nodes.removeValue(forKey: victim.id)
            NSLog("[Insight] evicted node \(victim.id) (level=\(victim.level), \(victim.rawBufferForCap) bytes)")
        }
    }

    // MARK: - scope_hint validation (Decision 10 §6 — preserved from v1 T2 fix bb828a9)

    /// Validate a list of model-emitted file paths. Returns only those that are inside
    /// `folderURL` (after symlink resolution AND standardisation, in that strict order)
    /// and have a `.md` extension. Path-separator-aware containment (defeats sibling
    /// collisions like `/foo` vs `/foobar`).
    private func validateScopeHint(_ paths: [String]) -> [URL] {
        let resolvedFolder = folderURL.resolvingSymlinksInPath().standardizedFileURL
        let folderResolvedPath = resolvedFolder.path
        let folderPathPrefix = folderResolvedPath.hasSuffix("/")
            ? folderResolvedPath
            : folderResolvedPath + "/"

        var result: [URL] = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: trimmed, relativeTo: folderURL)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let candidatePath = candidate.path

            let inside = (candidatePath == folderResolvedPath) ||
                         candidatePath.hasPrefix(folderPathPrefix)
            guard inside else {
                NSLog("[Insight] scope_hint rejected: %@ — outside folder or symlink escape", Self.sanitizeForLog(trimmed))
                continue
            }
            guard candidate.pathExtension.lowercased() == "md" else {
                NSLog("[Insight] scope_hint rejected: %@ — non-md", Self.sanitizeForLog(trimmed))
                continue
            }
            // Existence check — `URL(fileURLWithPath:)` does not verify the
            // file is actually on disk. LLM-emitted scope_hint paths often
            // hallucinate file names (e.g. "Module 1.md" when the real file
            // is "Module 1 - Innovation Life Cycles.md"). Without this guard
            // the read in buildSkeleton would silently throw → wrappedFiles
            // ends up empty → "No readable files in folder" fallback.
            guard FileManager.default.fileExists(atPath: candidatePath) else {
                NSLog("[Insight] scope_hint rejected: %@ — file does not exist", Self.sanitizeForLog(trimmed))
                continue
            }
            result.append(candidate)
        }
        return result
    }
}

// MARK: - Internal Errors

/// Errors specific to InsightSession's pipeline (cache write failures, missing
/// dependencies, etc.). Routed through the same `handleStreamError` pattern table as
/// AIProviderError cases.
enum InsightSessionError: Error {
    case cacheWriteFailed(String)
}
