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

        // Build root node and register it.
        let root = InsightNode(
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
        statusMessage = "Phase 1: building skeleton..."

        let nodeId = root.id
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let skel = try await self.phase1Skeleton(for: nodeId)
                try Task.checkCancellation()
                try await self.phase2StreamSections(for: nodeId, skeleton: skel)
                try Task.checkCancellation()
                try self.writeFinalHTMLToCache(nodeId: nodeId)
            } catch {
                self.handleStreamError(error, forNodeId: nodeId)
            }
            // Single-owner cleanup — clear the slot regardless of success/failure.
            self.activeTask = nil
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
        statusMessage = "Phase 1: building skeleton..."

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
        statusMessage = (nodes[nodeId]?.status == .ready) ? "Ready (cached)" : ""

        // Cache read — best-effort. Miss is OK (fresh node mid-stream, or cache cleaned).
        cachedNodeHTML = (try? cache.readNode(nodeId: nodeId))
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
        statusMessage = "Phase 1: building skeleton..."

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
        let scopedFiles: [URL]
        switch node.scope {
        case .folderRoot:
            scopedFiles = mdFiles
        case .topic(_, _, let files):
            scopedFiles = files.isEmpty ? mdFiles : files
        }

        try Task.checkCancellation()
        let parsed = try await rag.buildSkeleton(
            folderURL: folderURL,
            mdFiles: scopedFiles,
            scopeLabel: node.scope.label,
            scopeHint: node.scope.hint
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
            self.statusMessage = "Phase 2: streaming sections (0/\(validatedSections.count))..."
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
                folderURL: folderURL
            )
            preparedPrompts.append((section: section, systemPrompt: prompts.systemPrompt, userMessage: prompts.userMessage))
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
                ? "Ready"
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

        // Mirror to the published @MainActor map.
        if currentNodeId == forNodeId {
            currentNodeSections[sectionId] = state
            // Status-bar progress.
            let total = node.sectionStates.count
            let ready = node.sectionStates.values.filter { $0.status == .ready }.count
            statusMessage = "Phase 2: streaming sections (\(ready)/\(total))..."
        }

        // Per-session cap (Decision 10 §7).
        enforceSessionMemoryCap()
    }

    /// Section-stream completed successfully — flip the section's status to `.ready`
    /// and update the status bar.
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
            let total = node.sectionStates.count
            let ready = node.sectionStates.values.filter { $0.status == .ready }.count
            statusMessage = ready == total
                ? "Ready"
                : "Phase 2: streaming sections (\(ready)/\(total))..."
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
            let total = node.sectionStates.count
            let ready = node.sectionStates.values.filter { $0.status == .ready }.count
            let failed = node.sectionStates.values.filter { $0.status == .failed }.count
            statusMessage = "Phase 2: \(ready)/\(total) ready, \(failed) failed..."
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

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <title>\(escapedTitle)</title>
        \(libRefs)
        </head>
        <body>
        <header class="insight-chrome insight-breadcrumbs">\(breadcrumbHTML)</header>
        <main class="insight-content">
        \(sectionsHTML)
        </main>
        <footer class="insight-chrome insight-status"></footer>
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
