---
created: 2026-04-30
status: approved
branch: feature/recursive-insight
size: L
---

# Tech Spec: Recursive Insight

## Solution

Recursive Insight is a new tab-mode in MarkView that analyzes a folder of `.md` files as an on-demand tree of LLM-generated summaries. Root summary covers the whole folder; each summary ends with a list of deep-dive topics; clicking a topic streams a new, narrower summary of just the relevant files. Tree lives only in memory for the lifetime of the tab.

The implementation introduces three new capabilities to the codebase:

1. **First streaming code path** — a new `AIProviderClient.streamCompletion(...)` method using `URLSession.bytes(for:)` against Anthropic's SSE endpoint. All existing AI calls in MarkView are non-streaming one-shots; nothing else in the project uses SSE.
2. **First non-file tab kind** — `OpenTab` gains a `kind: TabKind` field. `case file` (default) preserves all existing call sites; `case insight(InsightSession)` carries the in-memory tree for an insight tab.
3. **First folder-content map-reduce in GraphRAG** — `GraphRAG.mapReduceForFolder(...)` reads actual `.md` file bodies clustered by community, producing a streamable summary. Existing `deepResearch()` only sees module names + counts and is unsuitable.

The WebView gains a new `state.mode = 'insight'` (precedent: `'source'`, `'preview'`, `'structured'`, `'structured-source'`) with a split-pane layout — center markdown + right deep-dive list + top breadcrumbs + bottom Save/Up buttons. Existing `markdown-it` and Mermaid pipelines are reused with one adjustment: per-block `try/catch` around `mermaid.run` so a single bad LLM-generated diagram doesn't abort the batch.

The orchestration layer (`AIOrchestrator`) is bypassed entirely. It is hard-coupled to `BlockExtractionResult` (entities/claims/relations) and cannot host streaming jobs without major refactor. Instead, `InsightSession` calls `AIProviderClient` directly, mirroring the existing `WorkspaceManager.translateDocument(...)` pattern (Models/WorkspaceManager.swift L1105-1191) which creates a tab and progressively mutates `tab.content` via `tabsStore.updateTab`.

Test infrastructure is a known gap (no `MarkViewTests` target exists). Per user decision, tests for this feature are deferred to a follow-up task tracked in `tasks/todo.md`. Verification for this feature relies on `xcodebuild build` and manual user testing.

## Architecture

### What we're building/modifying

**New files:**

- **`MarkView/Models/InsightSession.swift`** — class managing the in-memory `InsightNode` tree per tab. Owns navigation (current node, breadcrumbs path, expand/up/cancel), holds reference to `AIProviderClient`, exposes `@Published` state for SwiftUI/bridge forwarding.

**Modified files:**

- **`MarkView/Models/AIProviderClient.swift`** — add `streamCompletion(systemPrompt:userMessage:model:maxTokens:onDelta:)` and `case streamingError(String)` to `AIProviderError`. Reuses existing `apiKey`, headers, base URL.
- **`MarkView/Models/DocumentState.swift`** — add `enum TabKind { case file; case insight(InsightSession) }`. Add `var kind: TabKind = .file` to `OpenTab` (default value preserves source compat).
- **`MarkView/Models/GraphRAG.swift`** — add `mapReduceForFolder(folderURL:mdFiles:question:onDelta:)` that uses existing `detectCommunities()` for clustering, then reads actual `.md` file bodies per community for the map step, streams the reduce step via `AIProviderClient.streamCompletion`.
- **`MarkView/Models/WorkspaceManager.swift`** — add `startRecursiveInsight()` method, `scanMarkdownFiles(in:)` helper (extracts the duplicated enumerator pattern at L553/L930/L1564), `hasMarkdownFiles` computed property for menu enabled-state, branch in `closeTab(at:)` for `.insight` kind to call `session.cancel()`.
- **`MarkView/Views/ContentView.swift`** — add `Button("🧭 Recursive Insight")` to the `Section("Analysis")` (L124-130), disabled when no folder is open or no `.md` files found.
- **`MarkView/Views/EditorView.swift`** — branch in `loadContentIfNeeded(_:documentURL:)` (L194-227) on `tab.kind`: if `.insight(session)`, route to `bridge.loadInsightView(session:into:)` instead of standard markdown loading. Subscribe to `session.streamingBuffer` updates.
- **`MarkView/Bridge/WebViewBridge.swift`** — add 5 Swift→JS commands: `loadInsightView`, `appendInsightDelta`, `setInsightDeepDives`, `showInsightLoading`, `setInsightError`. Add 5 JS→Swift message types: `insightDeepDiveClicked`, `insightSaveRequested`, `insightBreadcrumbClicked`, `insightUpClicked`, `insightRetryRequested`. Extend `WebViewBridgeDelegate` protocol.
- **`MarkView/Resources/Editor/index.html`** — add `state.mode === 'insight'` branch in mode switching. New DOM template for split-pane layout. Implement debounced (~150ms) re-render on delta append. Implement `---DEEP-DIVES---` marker parser (only last occurrence, requires `\n\n` boundaries). Per-block try/catch around `mermaid.run`.

### How it works

**Trigger flow:**

1. User opens a folder via standard `openFolder` flow → `WorkspaceManager.rootNode` is set.
2. User clicks `AI Tools → Analysis → 🧭 Recursive Insight` in `ContentView` toolbar menu.
3. `WorkspaceManager.startRecursiveInsight()` runs:
   - Calls `scanMarkdownFiles(in: rootNode.url)` to enumerate all `.md` files (skipping hidden + `.dde`).
   - Creates `InsightSession(folderURL:, mdFiles:, providerClient:, graphRAG:)`.
   - Creates `OpenTab` with `kind: .insight(session)`, placeholder URL `file:///<folder>/.insight-<uuid>` (never written to disk).
   - Appends tab via `tabsStore.appendTab(tab)`.
   - Spawns `Task { await session.generateRoot() }`.

**Root node generation:**

- If `mdFiles.count <= 30`: `InsightSession` reads all `.md` bodies, concatenates with file headers, builds single prompt, calls `providerClient.streamCompletion(...)` with `onDelta` appending to `session.streamingBuffer`.
- If `mdFiles.count > 30`: `InsightSession` calls `graphRAG.mapReduceForFolder(...)`. GraphRAG groups files by community (via `detectCommunities()`), runs N parallel non-streaming map calls (each summarizing one community's files), then composes a reduce prompt and uses `streamCompletion` for the reduce step (which is what the user sees streaming).

**Streaming pipeline (per node):**

```
AIProviderClient.streamCompletion
    → URLSession.bytes(for: SSERequest)
    → for try await line in bytes.lines
        → parse SSE event "content_block_delta"
        → onDelta(textChunk)
            → InsightSession.streamingBuffer += textChunk  [@MainActor]
                → @Published triggers EditorView observer
                    → bridge.appendInsightDelta(sessionId, textChunk, into: webView)
                        → JS: window.appendInsightDelta(sessionId, deltaText)
                            → JS appends to session.bufferText
                            → JS schedules debounced renderInsight() (~150ms)
                                → md.render(bufferText) into center pane
                                → process mermaid blocks one-at-a-time, per-block try/catch
                                → check for "---DEEP-DIVES---" marker
                                    → if found: split, render right-pane topic list
```

**Marker parsing rules:**

- Marker exact form: `\n\n---DEEP-DIVES---\n` (newlines required to disambiguate from `---` horizontal rules in markdown).
- Parser scans for **last** occurrence in buffer (in case the marker hint appears earlier in markdown body).
- Topic format after marker (one per line): `- <Label> :: <hint> :: <scope_hint>` where `scope_hint` is a comma-separated list of relative file paths or glob patterns.

**Deep-dive expansion:**

1. User clicks topic in right pane → JS posts `{type: "insightDeepDiveClicked", payload: {sessionId, topicIndex}}`.
2. `WebViewBridgeDelegate.didRequestInsightDeepDive(sessionId:topicIndex:)` → forwards to `WorkspaceManager` → finds session by ID → calls `session.expand(deepDiveIndex:)`.
3. `InsightSession.expand` creates child `InsightNode`, makes it current, builds new prompt:
   - System prompt: same template
   - User prompt includes parent summary excerpt + child topic label/hint + bodies of files matching `scope_hint`
4. Streaming starts; UI updates breadcrumbs (`Root > Auth`); previous current node retained in tree (back-navigation).

**Navigation:**

- **Breadcrumb click** → `insightBreadcrumbClicked` → `session.navigateTo(nodeId:)` → switches `currentNode`, calls `bridge.loadInsightView(session:)` to repaint center+right with cached node content (no LLM call).
- **`↑ Up` button** → `insightUpClicked` → `session.up()` → equivalent to clicking parent breadcrumb.

**Save as .md:**

1. User clicks `💾 Save as .md` → JS posts `{type: "insightSaveRequested", payload: {sessionId}}`.
2. `WebViewBridgeDelegate.didRequestInsightSave(sessionId:)` → forwards to `WorkspaceManager` → opens `NSSavePanel` → on OK, writes `session.currentNode.markdownBody` (without `---DEEP-DIVES---` section, without breadcrumbs) to selected URL.

**Tab close:**

- `WorkspaceManager.closeTab(at:)` checks `tab.kind`. If `.insight(session)`: `session.cancel()` (cancels in-flight stream Task), `tabsStore.removeTab(at:)`. ARC frees `InsightSession` (and its tree of `InsightNode`) since `OpenTab` held the only strong reference. No `isModified` save prompt for insight tabs.

### Shared resources

| Resource | Owner (creates) | Consumers | Instance count |
|----------|----------------|-----------|----------------|
| `AIProviderClient` | `AIOrchestrator` (existing, reused) | `InsightSession` (new), `GraphRAG.mapReduceForFolder` (new) | 1 (singleton per workspace, accessed via `incrementalCompiler.orchestrator.providerClient`) |
| `GraphRAG` | `WorkspaceManager` (existing, reused) | `InsightSession` (new) | 1 (singleton per workspace) |
| `URLSession.shared` | system | `streamCompletion` (new) | 1 (system shared) |

## Decisions

### Decision 1: Bypass AIOrchestrator instead of extending it

**Decision:** `InsightSession` calls `AIProviderClient.streamCompletion(...)` directly, not through `AIOrchestrator.submit()`.

**Rationale:** `AIOrchestrator.executeJob` (Models/AIOrchestrator.swift L140-226) only knows how to call `providerClient.extractBlockSemantics(...)` and persist `BlockExtractionResult` (entities/claims/relations). The `AIJobType` enum has 28 cases all matching that shape. Adding streaming would force a major refactor of the job execution path and result handling. The closest existing analog is `WorkspaceManager.translateDocument(...)` (L1105-1191) which also bypasses the orchestrator and calls `providerClient` directly — proven pattern.

**Alternatives considered:**
- Extend `AIJobType` with `.insightNode` and add streaming branch in `executeJob`. Rejected: forces all jobs to support optional streaming callbacks, complicates queue mechanics.
- Wrap `streamCompletion` as a fake non-streaming job that buffers internally. Rejected: defeats the purpose of streaming (user must see live updates).

### Decision 2: Single streaming call with `---DEEP-DIVES---` delimiter

**Decision:** One LLM call per node returns markdown body + delimiter + deep-dive list in a single SSE stream. JS parses on-the-fly.

**Rationale:** Two separate calls (one for markdown, one for topics) doubles latency and prevents the user from seeing live progress on the topic list. JSON streaming with structured output is supported by Anthropic but harder to render incrementally — markdown can be re-rendered on each chunk; partial JSON cannot. Delimiter is simple, reliable, and the user-visible markdown is human-readable.

**Alternatives considered:**
- Two API calls (markdown then topics). Rejected: doubles latency, no live topic feedback.
- Streaming JSON with `summary_md` and `deep_dive_topics` keys. Rejected: partial JSON fragments cannot render as markdown until complete.
- XML tags `<summary>...</summary><deep_dives>...</deep_dives>`. Rejected: same parsing complexity as delimiter, less natural for the model.

### Decision 3: Tree lives in JS+Swift memory only, never persisted

**Decision:** No SQLite tables added. `InsightSession` holds `InsightNode` tree as Swift class hierarchy. Closing tab frees everything via ARC.

**Rationale:** Per user-spec, each analysis session is unique to user intent — caching root summaries between sessions has no clear benefit and complicates invalidation (when do we evict if files change?). For long-term keeping, user clicks `Save as .md` which produces a normal markdown file.

**Alternatives considered:**
- New `insight_nodes` table in SemanticDatabase. Rejected: not needed per user-spec, requires invalidation strategy on file changes.
- Reuse existing `artifacts` table. Rejected: same problem, also conflates ephemeral exploration with persistent build artifacts.

### Decision 4: Add `kind: TabKind` field to `OpenTab` (default `.file`)

**Decision:** Extend `OpenTab` (Models/DocumentState.swift L42) with `var kind: TabKind = .file`. New `enum TabKind { case file; case insight(InsightSession) }`.

**Rationale:** Default value preserves source compat for ~12 existing call sites that read `tab.url` / `tab.content`. Only three sites need to switch on `kind`: `EditorView.loadContentIfNeeded`, `WorkspaceManager.closeTab`, `TabBarView` display name. Alternative of using a synthetic URL scheme like `insight:///<id>` would require fragile URL inspection in many places and might break file-system-assuming code paths.

**Alternatives considered:**
- Synthetic URL scheme `insight://`. Rejected: fragile, requires URL inspection everywhere.
- Separate `OpenInsightTab` parallel structure. Rejected: requires duplicating `tabsStore` and `activeTabIndex` machinery.

### Decision 5: Extend GraphRAG to read file bodies (new method, don't modify existing)

**Decision:** Add `GraphRAG.mapReduceForFolder(folderURL:mdFiles:question:onDelta:)` that reads actual `.md` bodies. Existing `deepResearch()` left untouched.

**Rationale:** Existing `deepResearch()` (GraphRAG.swift L108-164) only sends `"Module: <name> (<count> files)"` to the model — useful for "which module owns X" semantic queries but not for content summarization which needs actual prose. Even though `deepResearch()` currently has zero callers in the codebase, separating the two functions keeps each one's prompt and context shape stable: `deepResearch` answers metadata questions, `mapReduceForFolder` summarizes content. Mixing them would entangle two different prompt strategies in one method.

**Thresholds (pinned):**
- **Folder-size cutoff:** > 30 .md files → use `mapReduceForFolder`; ≤ 30 → single `streamCompletion` call.
- **Per-file cap:** files > 50 KB are truncated to first 50 KB with a `[truncated]` marker before being sent in any prompt.
- **Per-community map cap:** if summed body of a community > 200 KB, subdivide into chunks of ≤ 200 KB and emit one map call per chunk; community label preserved across chunks.
- **Hard folder cap:** > 500 .md files → return error to user ("folder too large for Recursive Insight; use a subfolder").
- **Per-file count cap inside `scope_hint`:** deep-dive prompts include at most 30 files; if scope_hint resolves to more, take the 30 files closest in path to parent's scope.

**Alternatives considered:**
- Don't reuse GraphRAG at all; build map-reduce inside `InsightSession`. Rejected: community clustering logic would be duplicated and `InsightSession` would couple to `SemanticDatabase`.
- Modify `deepResearch()` to read bodies. Rejected: changes the meaning of an existing public method — even with zero callers today, a future change calling `deepResearch` for its current metadata-summarization shape would silently get prose summarization instead.

### Decision 6: JS-side debounce for re-render (~150ms)

**Decision:** Swift fires `appendInsightDelta` on every SSE chunk; JS coalesces with a 150ms debounce timer before calling `md.render()`.

**Rationale:** SSE chunks may arrive at >50/sec for fast models. `evaluateJavaScript` is cheap (~0.1ms each), but `md.render()` + Mermaid post-processing are ~10-50ms each — running them per chunk would jank the WebView. Debouncing in JS keeps Swift simple (just append + post) and gives a smooth perceived stream (~6-7 visible updates per second).

**Alternatives considered:**
- Debounce in Swift (buffer N chunks before forwarding). Rejected: Swift would need to know about render cost, JS is the natural debounce point.
- No debounce, render every chunk. Rejected: visible jank, especially on Mermaid-heavy summaries.

### Decision 7: Per-block try/catch around mermaid.run

**Decision:** In insight mode, render Mermaid blocks one at a time, each in `try/catch`. On error, replace the block with raw fenced code + error label. Existing editor mode left untouched.

**Rationale:** LLM-generated Mermaid mid-stream may be malformed (incomplete syntax during streaming, invalid node IDs, unclosed subgraphs). Existing `mermaid.run({nodes: nodes})` (index.html L1241-1254) processes a batch; one bad block can throw and abort the rest. Mermaid is also initialized once with `startOnLoad: false` (index.html L1097-1103) — for insight mode we additionally pass `securityLevel: 'strict'` per-render to prevent click-handler injection from LLM-generated mermaid source.

**Alternatives considered:**
- Skip Mermaid until stream completes, then render once. Rejected: defeats the live-feedback goal; user wants to see diagrams render incrementally.
- Always use per-block try/catch (apply to editor too). Rejected: out of scope; editor's batch mode is faster for static documents.

### Decision 8: Anthropic model — `claude-sonnet-4-6`

**Decision:** Default model for both root and deep-dive nodes is `claude-sonnet-4-6` (matches existing `AIProviderClient.model` constant at L7). Configurable via parameter to `streamCompletion`, but no UI to change it for this feature.

**Rationale:** Sonnet 4.6 is the latest available Sonnet (per system: Opus 4.7, Sonnet 4.6, Haiku 4.5) and the model already used throughout MarkView for extraction. Opus 4.7 would give better summaries but ~5x cost — out of scope for the default. If user later wants per-call model selection, that's an additive UI change.

**Alternatives considered:**
- Opus 4.7 default. Rejected: cost, also user said "наверное, санэт" with hesitation.
- Auto-switch to Opus for root, Sonnet for deep-dives. Rejected: premature optimization.
- Settings UI for model selection. Rejected: scope creep, can be added later.

### Decision 9: Tests deferred to follow-up

**Decision:** No tests written for this feature. Test-target setup tracked in `tasks/todo.md` as separate post-feature task. **Fixture files committed now** even without test code, so the eventual tests have golden inputs locked in before retroactive coverage.

**Rationale:** Project has no `MarkViewTests` target, no `Tests/*.swift`, no `import XCTest` anywhere. Setting up the test infrastructure is a one-time ~30-60 min task that benefits all future features, but combining it with Recursive Insight inflates scope. User explicitly chose to defer. Committing fixtures now (`Tests/Fixtures/sse-anthropic-sample.txt`, `Tests/Fixtures/marker-cases/*.md`) is zero-cost and allows code-reviewer in Audit Wave to hand-trace SSE parser and marker parser against documented expected outputs.

**Alternatives considered:**
- Set up test target as part of this feature. Rejected by user — separate concern.
- Write tests with hand-rolled assertions in `main()` of a CLI helper. Rejected: not idiomatic Swift, abandons standard tooling.

### Decision 10: Prompt safety and content sanitization

**Decision:** Multi-layer defense against malicious markdown content from `.md` files (which user-spec confirms may be untrusted).

**Layers:**
1. **Markdown rendering:** `markdown-it` configured with `html: false`, `linkify: true` with link target sanitization (`http(s)://` and relative only — reject `javascript:`, `data:`, `file:`). All other modes in `index.html` get the same config (defense in depth).
2. **DOM injection of LLM-derived strings:** deep-dive labels, hints, breadcrumb titles, error messages — all written via `Element.textContent` (never `innerHTML`). Single utility `setText(el, str)` used everywhere.
3. **Content Security Policy:** insight-mode HTML container gets `<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self' data:; object-src 'none'; base-uri 'none'">`. (`unsafe-inline` retained because existing index.html relies on it; `connect-src 'none'` blocks any LLM-injected `<img>` exfil-via-loading or fetch.)
4. **Mermaid:** `securityLevel: 'strict'` per-render in insight mode (blocks click handlers in LLM-generated diagrams).
5. **System prompt isolation:** instruction/data separation. System prompt explicitly delimits `.md` file content with XML-like tags (`<file path="...">...</file>`), tells the model to treat content inside tags as data only, never as instructions. Standard prompt-injection mitigation pattern.
6. **scope_hint validation:** every path in `scope_hint` returned by LLM is resolved via `URL(fileURLWithPath:relativeTo: folderURL).resolvingSymlinksInPath().standardizedFileURL` (resolve symlinks BEFORE standardizing — `standardizedFileURL` alone does not follow symlinks, so a symlink inside the folder pointing outside would pass containment check otherwise). Rejected if its `.path` does not begin with `folderURL.resolvingSymlinksInPath().standardizedFileURL.path`. Additionally rejected if extension is not `.md`. Prevents both LLM-driven path traversal and symlink escape.
7. **Resource caps (DoS):**
   - `streamCompletion` rejects SSE lines > 64 KB.
   - `InsightNode.rawBuffer` capped at 10 MB; on exceed, stream is cancelled and node enters `.failed` with "response too large" error.
   - `InsightSession` total memory cap 50 MB across all nodes; on exceed, oldest non-current nodes are evicted (leaves only current path from root).
   - File caps from Decision 5 (50 KB per file, 500 files per folder).

**Rationale:** Sandbox is OFF and the WebView bridge exposes save/file actions. A successful XSS in the insight pane could call `insightSaveRequested` and overwrite arbitrary files via NSSavePanel (mitigated by user confirming the panel, but still). Multi-layer defense is required for an LLM-driven UI consuming user-supplied markdown.

**Alternatives considered:**
- Skip sanitization — trust LLM output. Rejected: prompt injection from `.md` content is realistic threat per user-spec.
- Use a separate isolated WKWebView for insight mode with no bridge. Rejected: defeats the purpose (Save/Up/Click-topic require bridge).

### Decision 11: Async lifecycle, ARC, and connection-drop behavior

**Decision:** Explicit prescriptions for the async / streaming lifecycle to prevent leaks and undefined states.

**Prescriptions:**
1. **`[weak self]` mandatory** in every closure capture inside `InsightSession` that is held by a `Task`, `URLSession.bytes` iterator, or `onDelta` callback. Strong `self` capture in long-lived async contexts is the documented retain-cycle path.
2. **`activeTask` ownership:** `InsightSession.activeTask: Task<Void, Never>?` is the single owner of any in-flight stream Task. `cancel()` invariably calls `activeTask?.cancel()` then `activeTask = nil`. `expand()` cancels the previous activeTask before starting a new one.
3. **Connection drop / mid-stream throw behavior:**
   - Buffer state: `streamingBuffer` and `currentNode.rawBuffer` are **preserved** (user can read partial summary).
   - Node status: `currentNode.status = .failed` with `lastError` populated.
   - UI: JS receives `setInsightError(sessionId, message, retryable: true)` and displays a small error banner above the deep-dive list with `[Retry]` button. Retry button posts `insightRetryRequested` which Swift-side maps to `session.retryCurrent()` — re-runs same prompt, replaces the failed node's content (does not create a new node).
   - **Retry throttle:** sliding window of 3 retries per 60s per node. 4th attempt within window is rejected immediately with `setInsightError(message: "retry rate limit", retryable: false)` — banner becomes terminal, no Retry button. Window resets on successful completion of any retry. Prevents token-cost runaway from a stuck retry loop.
4. **Cancellation race:** if user closes tab while stream is in flight, `closeTab` calls `session.cancel()` synchronously **before** `tabsStore.removeTab`. The `Task` running the stream observes `Task.isCancelled` between SSE chunks and exits cleanly without writing to the now-orphaned session.
5. **Tab switch during stream:** stream continues in the background; `streamingBuffer` keeps accumulating. When user switches back, JS re-renders from the current `streamingBuffer` snapshot. No re-stream, no data loss.

**Rationale:** Without explicit prescription, ARC + Task semantics produce divergent implementations: some devs use strong `self`, some leak the entire tree on close. The connection-drop behavior is the most user-visible edge case and was unspecified in the original draft.

**Alternatives considered:**
- Discard partial buffer on error. Rejected: throws away possibly-useful partial content.
- Do nothing special on tab switch — re-stream from scratch. Rejected: wastes user time and tokens.
- Auto-retry on transient errors. Rejected: silent retry hides failure modes; explicit user-triggered retry is clearer.

## Data Models

No SQLite changes. Pure in-memory Swift types.

```swift
// MarkView/Models/InsightSession.swift (NEW)

@MainActor
final class InsightSession: ObservableObject, Identifiable {
    let id = UUID()
    let folderURL: URL
    let mdFiles: [URL]
    private let providerClient: AIProviderClient
    private let graphRAG: GraphRAG?

    @Published private(set) var rootNode: InsightNode?
    @Published private(set) var currentNodeId: UUID?
    @Published private(set) var streamingBuffer: String = ""  // raw stream text for current node
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var lastError: String?

    private var nodes: [UUID: InsightNode] = [:]
    private var activeTask: Task<Void, Never>?

    init(folderURL: URL, mdFiles: [URL], providerClient: AIProviderClient, graphRAG: GraphRAG?)

    func generateRoot() async
    func expand(deepDiveIndex: Int) async
    func navigateTo(nodeId: UUID)
    func up()
    func cancel()
    func retryCurrent() async              // re-run prompt for current node, replace content in-place
    func currentNode() -> InsightNode?
    func breadcrumbs() -> [InsightNode]   // root → ... → current
    func snapshot() -> InsightViewSnapshot // for bridge: markdown + topics + breadcrumbs
    private func handleStreamError(_ error: Error)  // sets node.status=.failed, lastError, fires setInsightError
}

// Retry-throttle: max 3 retries per node per 60s window. Fourth attempt within window
// returns AIProviderError.streamingError("retry rate limit") and surfaces to UI.

final class InsightNode: Identifiable {
    let id = UUID()
    let parentId: UUID?
    let level: Int
    let title: String              // breadcrumb label
    let scope: NodeScope           // .folderRoot | .topic(label, hint, files)
    var rawBuffer: String = ""     // full stream including marker
    var markdownBody: String = ""  // parsed markdown (before marker)
    var deepDives: [DeepDiveTopic] = []
    var children: [UUID] = []      // expanded child node IDs
    var status: Status = .pending  // .pending | .streaming | .ready | .failed
    var generatedAt: Date?
    let model: String              // "claude-sonnet-4-6"
}

enum NodeScope {
    case folderRoot
    case topic(label: String, hint: String, files: [URL])
}

struct DeepDiveTopic: Identifiable, Codable {
    let id = UUID()
    let label: String
    let hint: String
    let scopeHint: [String]  // file paths/globs from LLM
}

struct InsightViewSnapshot: Codable {
    let sessionId: String
    let nodeId: String
    let title: String
    let breadcrumbs: [BreadcrumbEntry]  // [{nodeId, title}]
    let markdown: String
    let deepDives: [DeepDiveTopic]
    let isStreaming: Bool
}

// MarkView/Models/DocumentState.swift (MODIFIED)

enum TabKind {
    case file
    case insight(InsightSession)
}

struct OpenTab: Identifiable {
    let id = UUID()
    let url: URL
    var content: String
    var originalContent: String
    var isModified: Bool = false
    var kind: TabKind = .file        // ← NEW (default preserves compat)
    var headings: [HeadingItem] = []
    // ... existing fields unchanged
}
```

```swift
// MarkView/Models/AIProviderClient.swift (MODIFIED — additive)

extension AIProviderClient {
    func streamCompletion(
        systemPrompt: String,
        userMessage: String,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 8192,
        onDelta: @escaping (String) -> Void
    ) async throws
}

enum AIProviderError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case parseError(String)
    case streamingError(String)  // ← NEW
}
```

```swift
// MarkView/Models/GraphRAG.swift (MODIFIED — additive)

extension GraphRAG {
    func mapReduceForFolder(
        folderURL: URL,
        mdFiles: [URL],
        question: String,
        onDelta: @escaping (String) -> Void
    ) async throws
}
```

## Dependencies

### New packages

None. Feature uses only Foundation, AppKit, SwiftUI, WebKit (all already in project).

### Using existing (from project)

- `AIProviderClient` — for both streaming and non-streaming Anthropic calls.
- `GraphRAG.detectCommunities()` — clustering primitive, reused as-is.
- `WebViewBridge` — generic message bus; new message types added.
- `WorkspaceManager.tabsStore` — for `OpenTab` lifecycle.
- `markdown-it`, `mermaid` (already loaded in index.html) — for client-side rendering.
- `FileManager.enumerator` — folder scan idiom, already used 3x in `WorkspaceManager`.

## Testing Strategy

**Feature size:** L

### Unit tests

**None for this feature.** Project has no `MarkViewTests` target. Test infrastructure setup tracked as follow-up in `tasks/todo.md`.

### Integration tests

**None for this feature.** Same reason.

### E2E tests

**None for this feature.** Same reason.

### Compensating verification

Since automated tests are deferred, this feature relies on:

1. **Build cleanness:** `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build` must succeed with 0 errors and ideally 0 new warnings.
2. **Manual smoke flow** by user (see "Agent Verification Plan" below).
3. **Code review (Audit Wave):** code-reviewer + security-auditor + test-master review the diff. test-master will explicitly note absence of tests is by design (per Decision 9) and verify no critical paths slip through unverified that the follow-up task wouldn't catch.

## Agent Verification Plan

**Source:** user-spec "Как проверить" section.

### Verification approach

The agent verifies build correctness; the user verifies behavior in the running app. No live MCP tools required (the feature lives entirely in the desktop app).

### Verification steps

| Step | Tool | Expected |
|------|------|----------|
| Project builds clean | `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build` | `BUILD SUCCEEDED`, 0 errors |
| Anthropic streaming endpoint reachable from current API key | `curl -N -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"claude-sonnet-4-6","max_tokens":256,"stream":true,"messages":[{"role":"user","content":"hi"}]}' https://api.anthropic.com/v1/messages` | SSE response with `event: content_block_delta` lines |

### Tools required

- `xcodebuild` (Xcode 15+, already required by project)
- `curl` (for one-time smoke check of streaming endpoint)

No Playwright, no Telegram, no Docker — desktop macOS app, manual UI verification only.

## Risks

| Risk | Mitigation |
|------|-----------|
| First SSE streaming code in the codebase — no prior art for `URLSession.bytes(for:)` parsing | Isolate in `AIProviderClient.streamCompletion(...)`, follow Anthropic SSE spec exactly (`event: content_block_delta` → `data: {...delta.text...}`). Manual smoke via curl before integration. |
| `OpenTab.kind` field added — risk of breaking ~12 read sites of `tab.url`/`tab.content` | Default value `.file` preserves all existing behavior. Only `EditorView.loadContentIfNeeded`, `WorkspaceManager.closeTab`, `TabBarView` display branch on kind. Build will catch any missed site. |
| `GraphRAG.mapReduceForFolder` may exceed context for very large folders | Per-community map step bounded by community size; reduce step takes only summaries, not bodies. If summed body of one community exceeds threshold, subdivide by file size (chunked map). |
| LLM produces malformed Mermaid mid-stream, breaking diagram render | Per-block try/catch in JS insight mode; on error show raw fenced code with error label. Won't abort the stream. |
| `---DEEP-DIVES---` marker collides with markdown horizontal rule | Marker requires `\n\n---DEEP-DIVES---\n` form (newlines on both sides). Parser scans for last occurrence only. |
| evaluateJavaScript per SSE chunk may flood main thread | JS-side 150ms debounce on `renderInsight()`. Swift fires per chunk; JS coalesces. |
| Tab close while stream in flight — Task continues writing to deallocated session | `InsightSession.cancel()` called in `closeTab` branch cancels active Task before tab removal. ARC then frees the session. |
| User clicks deep-dive while previous stream still active | `InsightSession.expand()` cancels current `activeTask` before starting new one (only one stream per session at a time). |
| Tests deferred — bugs in SSE parser, marker parser, lifecycle won't be caught automatically | Audit Wave reviews diff against committed fixture files (`Tests/Fixtures/sse-anthropic-sample.txt`, `Tests/Fixtures/marker-cases/*.md`). Build + manual user verification including Instruments leak check. Follow-up task in `tasks/todo.md` adds retroactive coverage. |
| Anthropic streaming API rate limit / network failure mid-stream | Decision 11 §3: `streamCompletion` propagates errors; `InsightSession.handleStreamError` sets `currentNode.status = .failed`, populates `lastError`, preserves partial `rawBuffer`. JS bridge `setInsightError(retryable:true)` shows banner + `[Retry]` button → `insightRetryRequested` → `session.retryCurrent()`. |
| Prompt injection from .md content steers LLM to emit XSS, exfiltrate paths, or generate poisoned `scope_hint` | Decision 10 multi-layer: markdown-it `html: false`, `textContent` for all LLM strings, CSP `connect-src 'none'`, mermaid `securityLevel: 'strict'`, system-prompt XML tag isolation, scope_hint folder-containment validation. |
| Resource exhaustion (giant folder, runaway response, deep recursion) | Per-file 50 KB cap, per-folder 500 file cap, per-node 10 MB rawBuffer cap, per-session 50 MB cap with oldest-non-current eviction, SSE line 64 KB cap. All listed in Decision 10 §7 + Decision 5. |
| ARC retain cycle leaks `InsightSession` + tree on tab close | Decision 11 §1: `[weak self]` mandatory in all closures captured by long-lived Tasks. Verified by code-reviewer. QA confirms via Instruments → Allocations: zero retained insight objects after tab close. |

## Acceptance Criteria

Technical acceptance (in addition to user-spec criteria):

**Build & compatibility:**
- [ ] `xcodebuild build` succeeds with 0 errors.
- [ ] No new compiler warnings introduced in modified files.
- [ ] All existing call sites that read `tab.url` / `tab.content` / `tab.isModified` continue to work without modification (default `kind: .file` preserves behavior).
- [ ] No regressions: opening an existing `.md` file still uses standard editor flow; AI Console / Translate / existing AI Tools still work.
- [ ] No new SQLite tables created. No writes to existing `artifacts` or `ai_jobs` tables for insight operations.
- [ ] `GraphRAG.deepResearch()` (existing method) unchanged in behavior.

**SSE & streaming correctness:**
- [ ] `AIProviderClient.streamCompletion` correctly parses Anthropic SSE format: handles `content_block_delta`, `message_stop`, `error` events; ignores `ping` and `message_delta` events; tolerates `: comment` SSE keepalive lines.
- [ ] `streamCompletion` propagates HTTP errors (non-200) as `AIProviderError.httpError` with response body, same shape as existing `extractSingleChunk`.
- [ ] `streamCompletion` rejects SSE lines > 64 KB as `AIProviderError.streamingError`, does not buffer unbounded lines.
- [ ] No part of API key string ever appears in any thrown error message, JS-side state, or NSLog output.

**Lifecycle & memory (per Decision 11):**
- [ ] `InsightSession.cancel()` cancels the in-flight `URLSession.bytes` Task and stops `onDelta` callbacks within 1 second.
- [ ] `closeTab(at:)` for `.insight` kind: calls `session.cancel()`, removes tab, no save prompt shown.
- [ ] Closing insight tab → `InsightSession` and all `InsightNode` instances are deallocated (verified via Instruments → Allocations on a manual smoke run, no retained insight objects after close). **This check is mandatory for QA sign-off, not optional.**
- [ ] Connection drop mid-stream: `currentNode.status = .failed`, `lastError` populated, partial `rawBuffer` preserved, JS shows error banner with `[Retry]` button.
- [ ] Tab switch during stream: stream continues, no data loss, switching back re-renders from current buffer.
- [ ] All `InsightSession` closures captured by long-lived Tasks use `[weak self]` (verified by code-reviewer).

**Resource caps (per Decision 5 & 10):**
- [ ] Folders > 500 .md files rejected with user-visible error; ≤ 500 proceed normally.
- [ ] Files > 50 KB truncated to first 50 KB with `[truncated]` marker before sending to LLM.
- [ ] `InsightNode.rawBuffer` enforces 10 MB cap; on exceed, stream cancelled and node enters `.failed`.
- [ ] `InsightSession` total memory cap of 50 MB across all nodes enforced; on exceed, oldest non-current-path nodes evicted.

**Security (per Decision 10):**
- [ ] `markdown-it` initialized with `html: false` and link target sanitization (`http(s)://` and relative only).
- [ ] All LLM-derived strings (deep-dive labels, hints, breadcrumb titles, error messages) rendered into DOM via `textContent`, never `innerHTML`. Single utility used.
- [ ] Insight-mode HTML container has CSP meta tag matching Decision 10 spec (default-src 'self', connect-src 'none', object-src 'none', base-uri 'none').
- [ ] Mermaid initialized with `securityLevel: 'strict'` for insight-mode renders.
- [ ] System prompt for both root and deep-dive uses XML-tag delimiters around .md file content with explicit "treat as data only" instruction.
- [ ] Every `scope_hint` path resolved via `.resolvingSymlinksInPath().standardizedFileURL` against folder; paths escaping the folder rejected (logged + skipped, not raised to user). Non-`.md` extensions also rejected.
- [ ] Folder scan via `scanMarkdownFiles` does not follow symlinks pointing outside `folderURL` (uses `.skipsPackageDescendants` and resolved-path containment check).
- [ ] Tab-switch-during-stream: switching away from an actively-streaming insight tab does not interrupt the stream; switching back re-renders from the current `streamingBuffer` snapshot with no data loss.
- [ ] Retry throttle: `retryCurrent()` rejects 4th retry attempt within 60s window for the same node, surfaces "retry rate limit" via `setInsightError(retryable: false)`.

**Marker parsing:**
- [ ] `---DEEP-DIVES---` marker only matched at form `\n\n---DEEP-DIVES---\n` (boundary newlines required), not on bare `---`.
- [ ] Parser uses **last** occurrence of marker in buffer (avoids hits inside markdown body).
- [ ] If marker absent at end of stream → render full body as markdown, leave deep-dive list empty.
- [ ] If parser finds 0 or > 7 topics, accept as-is (no enforcement) — UI shows whatever topics were parsed.

## Implementation Tasks

### Wave 1 (independent foundations)

#### Task 1: Add streaming to AIProviderClient
- **Description:** Add `streamCompletion(systemPrompt:userMessage:model:maxTokens:onDelta:)` to `AIProviderClient` using `URLSession.bytes(for:)` and Anthropic SSE parsing. Add `case streamingError(String)` to `AIProviderError`. Per Decision 10 §7: enforce 64 KB per-line cap; per Decision 11: API key must never appear in any error message. Tolerate `: ping` SSE keepalive lines and `event: error` events. Commit `Tests/Fixtures/sse-anthropic-sample.txt` (~5 example streams: happy path, partial chunks, ping comments, error event, oversized line) to lock parser behavior for retroactive tests.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Verify-smoke:** `curl -N -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"claude-sonnet-4-6","max_tokens":256,"stream":true,"messages":[{"role":"user","content":"count from 1 to 20 with brief explanation each"}]}' https://api.anthropic.com/v1/messages` — must produce multiple `content_block_delta` events across multiple TCP chunks, parser must reconstruct the full text correctly
- **Files to modify:** `MarkView/Models/AIProviderClient.swift`, `Tests/Fixtures/sse-anthropic-sample.txt` (new file)
- **Files to read:** `MarkView/Models/AIProviderClient.swift` (mirror existing patterns)

#### Task 2: Add TabKind enum and folder scan helper
- **Description:** Add `enum TabKind { case file; case insight(InsightSession) }` to `DocumentState.swift`. Add `var kind: TabKind = .file` to `OpenTab` (default preserves source compat). Add `scanMarkdownFiles(in:)` helper and `hasMarkdownFiles` computed property to `WorkspaceManager`, extracting the duplicated enumerator pattern from existing folder-scan sites. Per Decision 10 §7: helper must skip symlinks resolving outside the input folder, use `.skipsPackageDescendants`, and return error if file count > 500.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/DocumentState.swift`, `MarkView/Models/WorkspaceManager.swift`
- **Files to read:** `MarkView/Models/DocumentState.swift`, `MarkView/Models/WorkspaceManager.swift` (existing folder-scan sites near `excludeFolder`, `runStructuralIndex`, `analyzeAllFiles`)

#### Task 3: Extend GraphRAG with folder map-reduce
- **Description:** Add `mapReduceForFolder(folderURL:mdFiles:question:onDelta:)` to `GraphRAG`. Uses existing `detectCommunities()` for clustering, reads actual `.md` file bodies per community for map step (non-streaming, parallel), composes reduce prompt and calls `streamCompletion` for the reduce. Enforce all thresholds from Decision 5 (50 KB per-file truncation, 200 KB per-community subdivision, 500 file hard cap). Per Decision 10 §5: wrap each `.md` file body in `<file path="...">...</file>` XML tag and prepend instruction-isolation system prompt that treats wrapped content as data only. Existing `deepResearch()` left untouched.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/GraphRAG.swift`
- **Files to read:** `MarkView/Models/GraphRAG.swift`, `MarkView/Models/AIProviderClient.swift` (after Task 1)

### Wave 2 (depends on Wave 1)

#### Task 4: Create InsightSession and node tree
- **Description:** Create `InsightSession.swift` implementing the in-memory tree of `InsightNode` per insight tab. Methods: `generateRoot`, `expand(deepDiveIndex:)`, `navigateTo`, `up`, `cancel`, `retryCurrent`, `breadcrumbs`, `snapshot`, `handleStreamError`. Owns `streamingBuffer` (`@Published`) for bridge forwarding. Routes to `streamCompletion` (≤30 files) or `mapReduceForFolder` (>30 files). Per Decision 11: all closures captured by long-lived Tasks use `[weak self]`; `activeTask` is single owner; cancel-then-set-nil pattern; on connection drop preserve `rawBuffer`, set `node.status = .failed`, populate `lastError`. Per Decision 10 §6: validate every `scope_hint` path via `URL(...).resolvingSymlinksInPath().standardizedFileURL` containment against `folderURL.resolvingSymlinksInPath().standardizedFileURL`, reject non-`.md` extensions and path-traversal escapes (log + skip). Per Decision 10 §7: enforce 10 MB per-node `rawBuffer` cap, 50 MB per-session cap with oldest-non-current eviction. Per Decision 10 §5: build prompts using XML-tag instruction isolation around .md content.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/InsightSession.swift` (new file)
- **Files to read:** `MarkView/Models/AIProviderClient.swift`, `MarkView/Models/GraphRAG.swift`, `MarkView/Models/WorkspaceManager.swift` (`translateDocument` pattern as reference for tab-content streaming)

#### Task 5: Insight mode in WebView (HTML/JS)
- **Description:** Add `state.mode === 'insight'` branch in `index.html` with split-pane DOM (center markdown, right deep-dive list, top breadcrumbs, bottom Save/Up buttons, error banner above deep-dive list). Implement `appendInsightDelta` with debounced (~150ms) `md.render()` re-render and `---DEEP-DIVES---` marker parser (last occurrence only, requires `\n\n` boundaries, accept any topic count including 0). Per-block try/catch around `mermaid.run` with `securityLevel: 'strict'`. Per Decision 10: configure `markdown-it` with `html: false` and link target sanitization, render all deep-dive labels/hints/breadcrumb titles/error messages via `Element.textContent` (single utility), add CSP meta tag (`default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self' data:; object-src 'none'; base-uri 'none'`). Commit `Tests/Fixtures/marker-cases/*.md` (5 cases: happy, marker-in-code-fence, marker-as-hr, no-marker, multiple-markers) to lock parser behavior. Wire button clicks to bridge with new message types including `insightRetryRequested`.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Verify-user:** load any folder in dev build, trigger insight, verify split-pane renders correctly with theme support, paste a poisoned markdown file (with `<script>alert(1)</script>` and `[click](javascript:alert(1))`) into the test folder, confirm no script executes
- **Files to modify:** `MarkView/Resources/Editor/index.html`, `Tests/Fixtures/marker-cases/happy.md`, `Tests/Fixtures/marker-cases/in-code-fence.md`, `Tests/Fixtures/marker-cases/as-hr.md`, `Tests/Fixtures/marker-cases/no-marker.md`, `Tests/Fixtures/marker-cases/multiple-markers.md` (new files)
- **Files to read:** `MarkView/Resources/Editor/index.html` (existing state object, mermaid init/pipeline at `mermaid.initialize` and `mermaid.run({nodes})`, mode switching, window setter functions)

#### Task 6: WebViewBridge insight messages and EditorView routing
- **Description:** Add 5 Swift→JS commands to `WebViewBridge`: `loadInsightView(snapshot:into:)`, `appendInsightDelta(sessionId:text:into:)`, `setInsightDeepDives(sessionId:topics:into:)`, `showInsightLoading(sessionId:msg:into:)`, `setInsightError(sessionId:message:retryable:into:)`. Add 5 JS→Swift message types: `insightDeepDiveClicked`, `insightSaveRequested`, `insightBreadcrumbClicked`, `insightUpClicked`, `insightRetryRequested`. Extend `WebViewBridgeDelegate` protocol. In `EditorView.loadContentIfNeeded`, branch on `tab.kind`: if `.insight`, route to `bridge.loadInsightView(...)` and subscribe to `session.streamingBuffer` for delta forwarding. All Swift→JS string payloads use the existing array-wrap encoding idiom (single-element JSON array, drop wrapping brackets) to avoid `NSInvalidArgumentException`.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Bridge/WebViewBridge.swift`, `MarkView/Views/EditorView.swift`
- **Files to read:** `MarkView/Bridge/WebViewBridge.swift` (existing message dispatch + `loadContent` encoding pattern), `MarkView/Views/EditorView.swift` (existing `loadContentIfNeeded` routing)

### Wave 3 (depends on Wave 2)

#### Task 7: WorkspaceManager insight wiring
- **Description:** Add `startRecursiveInsight()` method to `WorkspaceManager`: scans `.md` files, creates `InsightSession`, opens new `OpenTab` with `kind: .insight(session)`, kicks off `session.generateRoot()`. Branch in `closeTab(at:)` for `.insight` kind: call `session.cancel()` synchronously **before** `tabsStore.removeTab` (per Decision 11 §4), skip save prompt. Implement bridge delegate methods for all 5 insight messages (deep-dive click, save, breadcrumb, up, retry) — forward to active session. Save handler opens NSSavePanel with default filename derived from current node title (sanitized to alphanumeric + underscores), writes `currentNode.markdownBody` (no marker, no deep-dives section).
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/WorkspaceManager.swift`
- **Files to read:** `MarkView/Models/WorkspaceManager.swift` (existing `translateDocument` for streaming pattern, `closeTab` for current dirty-save logic, `tabsStore` for tab API), `MarkView/Models/InsightSession.swift` (after Task 4)

#### Task 8: AI Tools menu integration
- **Description:** Add `Button("🧭 Recursive Insight")` to `Section("Analysis")` in the ContentView toolbar AI Tools menu (after "Generate Full Documentation"). Wire to `workspaceManager.startRecursiveInsight()`. Disabled when `rootNode == nil` or `!workspaceManager.hasMarkdownFiles`.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Verify-user:** open folder with .md files → AI Tools menu → see "🧭 Recursive Insight" enabled; close folder → menu item disabled
- **Files to modify:** `MarkView/Views/ContentView.swift`
- **Files to read:** `MarkView/Views/ContentView.swift` (existing AI Tools menu structure)

### Audit Wave

#### Task 9: Code Audit
- **Description:** Full-feature code quality audit. Read all source files created/modified in this feature: AIProviderClient.swift, DocumentState.swift, WorkspaceManager.swift, GraphRAG.swift, InsightSession.swift, WebViewBridge.swift, EditorView.swift, ContentView.swift, index.html, plus committed fixtures. Review holistically for: shared resources compliance (single AIProviderClient instance reused, no duplicate creation), Swift/AppKit conventions, error propagation across async boundaries, Task cancellation correctness, **`[weak self]` in every closure captured by long-lived Task per Decision 11 §1 — flag any strong `self` capture**, JS code quality, theme compatibility, and hand-trace SSE parser against `Tests/Fixtures/sse-anthropic-sample.txt` and marker parser against `Tests/Fixtures/marker-cases/*.md`. Write audit report to `logs/audit/code-audit.md`.
- **Skill:** code-reviewing
- **Reviewers:** none

#### Task 10: Security Audit
- **Description:** Full-feature security audit verifying Decision 10 layers actually shipped: (1) markdown-it `html: false` and link sanitization in insight mode; (2) `Element.textContent` for every LLM-derived string — **grep insight-mode JS for `innerHTML`, `outerHTML`, `document.write`, `insertAdjacentHTML`, `Function(`, `eval(`** and flag any usage on LLM-derived data (CSP retains `script-src 'unsafe-inline'` for compat with existing modes, so JS-side hygiene is the primary script barrier); (3) CSP meta tag present with required directives; (4) Mermaid `securityLevel: 'strict'` per-render; (5) system prompts use XML-tag instruction isolation around .md content; (6) `scope_hint` paths validated via `.resolvingSymlinksInPath().standardizedFileURL` containment + `.md` extension check; (7) all resource caps enforced (50 KB/file, 500 files/folder, 10 MB/node, 50 MB/session, 64 KB/SSE-line, 3 retries/60s); (8) API key never appears in error messages or NSLog; (9) NSSavePanel filename sanitization + forced `.md` extension. Write audit report to `logs/audit/security-audit.md`.
- **Skill:** security-auditor
- **Reviewers:** none

#### Task 11: Test Audit
- **Description:** Full-feature test quality audit. Project has no test target — by design per Decision 9 (deferred to follow-up). Verify: (a) deferral is correctly tracked in `tasks/todo.md` with owner + target date populated, (b) follow-up task lists the right test scope (SSE parser, marker parser, InsightSession lifecycle, GraphRAG mapReduceForFolder, scope_hint validation), (c) committed fixtures (`Tests/Fixtures/sse-anthropic-sample.txt` from Task 1, `Tests/Fixtures/marker-cases/*.md` from Task 5) are present, complete, and represent the documented edge cases, (d) Code Audit and Security Audit reports flag any specific area that should be tested before merge despite the deferral, (e) Pre-deploy QA's manual Instruments leak check is sufficient to catch the ARC-cycle risk that an automated test would have caught. Write audit report to `logs/audit/test-audit.md`.
- **Skill:** test-master
- **Reviewers:** none

### Final Wave

#### Task 12: Pre-deploy QA
- **Description:** Acceptance testing: verify all acceptance criteria from user-spec and tech-spec. Run `xcodebuild build`, verify 0 errors and no new warnings in modified files. Run smoke curl against streaming endpoint with multi-token output (recapture sse-anthropic-sample.txt fixture if drifted). Spot-check that no new tables in SemanticDatabase, no writes to artifacts/ai_jobs for insight operations. Verify all 10 user-spec acceptance criteria via manual flow on the TestFiles folder. **Mandatory: Instruments → Allocations leak check across 4 scenarios** — (a) open insight tab, expand 2-3 deep-dives, close tab; (b) trigger error path (kill network mid-stream), click Retry, succeed, close; (c) trigger 4th retry within 60s, observe rate-limit error, close; (d) generate enough deep-dive content to exceed 50 MB session cap, observe eviction of oldest non-current nodes, close. After each: force GC, verify zero retained `InsightSession` and `InsightNode` instances. Also manually verify tab-switch-during-stream (open insight, start stream, switch to another tab mid-stream, switch back — buffer continues accumulating, no data loss).
- **Skill:** pre-deploy-qa
- **Reviewers:** none
