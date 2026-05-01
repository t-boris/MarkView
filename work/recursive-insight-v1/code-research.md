---
created: 2026-04-30
status: research
type: code-research
feature: recursive-insight
---

# Code Research: Recursive Insight

Deep dive into the MarkView codebase to identify the exact integration points,
risks, and patterns to follow when implementing the Recursive Insight feature.
All file paths are absolute.

---

## 1. AIProviderClient.swift — Anthropic API integration

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/AIProviderClient.swift` (486 lines)

### Request shape (today, non-streaming)

Three call paths exist, all built around `URLSession.shared.data(for:)` (one-shot, awaits the full body). Identical header set across the file:

```swift
// L121-141 — extractSingleChunk
let body: [String: Any] = [
    "model": model,             // "claude-sonnet-4-6"
    "max_tokens": 16384,
    "system": "...",
    "messages": [["role": "user", "content": chunk]]
]
let data = try JSONSerialization.data(withJSONObject: body)
var request = URLRequest(url: URL(string: baseURL)!) // https://api.anthropic.com/v1/messages
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
request.httpBody = data
request.timeoutInterval = 180
let (responseData, response) = try await session.data(for: request)
```

Two model constants exist:
- `private let model = "claude-sonnet-4-6"` (L7) — extraction
- `private let diagramModel = "claude-opus-4-6"` (L294) — Mermaid generation

### Streaming (SSE) — NOT supported anywhere

`grep -n "stream\|SSE\|content_block_delta" AIProviderClient.swift` returns zero hits. There is no `URLSession.shared.bytes(for:)` usage anywhere in the project either (`grep -rn "URLSession.*bytes" MarkView/` is empty). For Recursive Insight we will introduce the **first** streaming code path in the codebase.

**Insertion point for streaming method:** new function next to `extractSingleChunk`, around L177. Suggested signature:
```swift
func streamCompletion(
    systemPrompt: String,
    userMessage: String,
    model: String = "claude-sonnet-4-6",
    maxTokens: Int = 8192,
    onDelta: @escaping (String) -> Void
) async throws
```
- Add `"stream": true` to the body dict.
- Use `URLSession.shared.bytes(for: request)` and iterate `for try await line in bytes.lines`.
- Parse SSE events: `event: content_block_delta` followed by `data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}`.
- Call `onDelta(text)` on each text_delta. Stop at `event: message_stop`.

### Existing error handling

```swift
// L472-486
enum AIProviderError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(Int, String)
    case parseError(String)
}
```

Pattern at every call site (L145-148, 376-379, 444-447):
```swift
guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
    let body = String(data: responseData, encoding: .utf8) ?? ""
    throw AIProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
}
```
For streaming we should add `case streamingError(String)` and `case parseError` is already reusable for malformed SSE chunks.

### API key plumbing

```swift
// L62-67, 463-469
init(apiKey: String? = nil) {
    self.apiKey = apiKey ?? Self.loadKeyFromKeychain()
}
private static let storageKey = "com.markview.dde.apikey"
static func loadKeyFromKeychain() -> String? {
    UserDefaults.standard.string(forKey: storageKey)
}
```
NB: despite the name `loadKeyFromKeychain`, the key actually lives in `UserDefaults`. Set via `setValue(apiKey, forHTTPHeaderField: "x-api-key")`. The recursive-insight streamer should reuse the existing `apiKey` instance variable on `AIProviderClient` — no new key plumbing required.

There is also an exposed accessor in `ActionEngine.swift` L260-264 used by `ResearchEngine`, `TestGenerator`, `GraphRAG`:
```swift
extension AIProviderClient {
    var apiKeyValue: String? {
        hasAPIKey ? UserDefaults.standard.string(forKey: "com.markview.dde.apikey") : nil
    }
}
```

### Implication for Recursive Insight

- Add a new `streamCompletion(...)` method to `AIProviderClient`.
- Add new error case for SSE parse failures.
- Reuse existing model constant + headers + key.
- No restructure of existing extraction/diagram methods needed — additive change.

---

## 2. AIOrchestrator.swift — job queue

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/AIOrchestrator.swift` (403 lines)

### AIJob structure

Defined in `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/SemanticModels.swift` L256-273:
```swift
struct AIJob: Identifiable, Codable {
    let id: String
    let jobType: AIJobType
    var priority: CompilationPriority
    var status: AIJobStatus
    let documentId: String?
    let blockIds: [String]
    let inputHash: String
    ...
    var costTokens: Int?
}
```

### AIJobType enum — 28 cases, NO streaming case

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/SemanticModels.swift` L275-304:
```swift
enum AIJobType: String, Codable {
    case extractBlockSemantics
    case extractClaims
    case extractTemporalStructure
    case rewriteForClarity
    ... 25 more cases ...
    case draftMissingSection
}
```
Status enum L306-308: `pending, inProgress, completed, failed, cancelled`.

For Recursive Insight we could add `case generateInsightNode` here, but **the orchestrator is tightly coupled to `BlockExtractionResult`** (see `executeJob` L140-226 — it only knows how to call `providerClient.extractBlockSemantics(...)` and persist `entities/claims/relations`).

### Queue mechanics

```swift
// L118-138
private let maxConcurrent = 3
private var runningCount = 0

private func processQueue() {
    guard !isPaused, !isDisabled else { return }
    while runningCount < maxConcurrent, !jobQueue.isEmpty {
        let job = jobQueue.removeFirst()
        runningCount += 1
        isProcessing = true
        Task {
            await executeJob(job)
            runningCount -= 1
            ...
        }
    }
}
```

### How results flow back

Two channels:
1. **DB persistence** — `handleExtractionResult` (L241-331) calls `db.upsertEntity/upsertClaim/upsertRelation`.
2. **`@Published`** — `extractedEntities/extractedClaims/extractedRelations` mutated on MainActor; SwiftUI panels observe via `@EnvironmentObject`.

There is no callback per-token, no streaming hook, no per-job result delegate.

### Cache integration

Inside `submitExtraction` (L72-83):
```swift
let inputHash = fnv1aHash(content)
if let cached = cacheManager.loadCachedResponse(inputHash: inputHash) {
    if let result = try? JSONDecoder().decode(BlockExtractionResult.self, from: cached) {
        handleExtractionResult(result, ...)
        return
    }
}
```
Cache stores only `BlockExtractionResult` JSON — not generic responses.

### Implication for Recursive Insight

- The orchestrator's job/queue/cache machinery is **purpose-built for structured extraction**. Shoehorning streaming insight calls into `AIJob` would force major refactor.
- **Recommendation:** bypass `AIOrchestrator` entirely. Create a separate `InsightSession` class (per-tab) that uses `AIProviderClient.streamCompletion(...)` directly. Concurrency: at most one active stream per session anyway (user navigates serially).
- **Reuse:** the orchestrator's `providerClient` instance (already wired to `incrementalCompiler.orchestrator.providerClient` in `WorkspaceManager` L504, 684). Pull it out for the new session.
- **No new AIJobType case needed.**

---

## 3. GraphRAG.swift — map-reduce deep research

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/GraphRAG.swift` (226 lines)

### Community detection

```swift
// L28-103
func detectCommunities() {
    let modules = db.allModules()
    guard modules.count > 5 else { return }
    // Build adjacency from struct_relations
    var adjacency: [String: Set<String>] = [:]
    for mod in modules {
        let rels = db.relationsForModule(mod.id)
        for rel in rels {
            adjacency[mod.id, default: []].insert(rel.targetId)
            adjacency[rel.targetId, default: []].insert(mod.id)
        }
    }
    // BFS connected-components
    ...
    communities = detectedCommunities
}
```
Operates on **`modules`** (rows in `modules` table populated by `StructuralIndexer`, NOT raw `.md` files). A "module" in MarkView terminology is a folder/directory that contains markdown files. `db.allModules()` returns rows from a `modules` table built by structural indexing.

### deepResearch() — map-reduce

```swift
// L108-164
func deepResearch(question: String) async -> String? {
    guard providerClient.hasAPIKey else { return nil }
    if communities.isEmpty { detectCommunities() }
    guard !communities.isEmpty else { return "No communities detected. Try regular Research instead." }

    // MAP: ask each community
    for community in communities {
        let modules = db.allModules().filter { community.moduleIds.contains($0.id) }
        let context = modules.map { "Module: \($0.name) (\($0.fileCount) files)" }.joined(separator: "\n")
        let mapPrompt = "..."
        if let answer = try? await callLLM(prompt: mapPrompt, maxTokens: 1024) {
            if !answer.contains("NOT_RELEVANT") { communityAnswers.append(...) }
        }
    }
    // REDUCE: merge all community answers
    let reducePrompt = "..."
    let finalAnswer = try? await callLLM(prompt: reducePrompt, maxTokens: 4096)
    db.upsertArtifact(id: "deepresearch_\(fnv1a(question))", ..., kind: "deep_research", ...)
    return finalAnswer
}

// L189-219 callLLM uses non-streaming URLSession.shared.data(for:)
```

### Important caveats for our use

1. The map context per community is **only module names + file counts** — not actual file content (`"Module: \($0.name) (\($0.fileCount) files)"`). This means `deepResearch()` answers from metadata, not from real `.md` file contents. **For Recursive Insight root summary that needs to actually read documentation text, this is not enough.**
2. `communities.isEmpty` returns "No communities detected" — happens when modules.count <= 5 (L30).
3. Returns a single non-streamed `String?`.

### Implication for Recursive Insight

The user-spec acceptance criterion (line 39) says: *"если папка содержит >30 .md-файлов, для root-узла используется существующий `GraphRAG.deepResearch()` map-reduce"*.

**Reality check:** `deepResearch()` as-is will not produce a useful summary because it sees only module names, not file bodies. We have two options:

- **A. Wrap, not reuse.** Build our own map-reduce in `InsightSession.generateRootForLargeFolder()` that:
  - Groups files by community ID using `graphRAG.communities` (after calling `detectCommunities()`).
  - For each community, reads actual `.md` file bodies of the modules in that community, sends to LLM, captures partial summary.
  - Reduces by another LLM call that streams to user.
- **B. Extend `GraphRAG`** with a new `deepResearchWithFileContents(folder:question:onDelta:)` that takes the folder URL, fetches file bodies, streams the reduce step. More invasive but reusable.

**Recommended:** Option A — keep `GraphRAG` untouched, treat its `detectCommunities()` + `communities` array as a clustering primitive only. Integration point: `InsightSession.generateRoot()` checks `mdFileCount > 30`, if so calls `workspaceManager.graphRAG?.detectCommunities()` then iterates `graphRAG.communities` to chunk file reads.

---

## 4. WorkspaceManager.swift — central state, tabs, AI tools

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/WorkspaceManager.swift` (2215 lines)

### Tab type — NO `kind` enum exists

`OpenTab` is defined in `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/DocumentState.swift` L42-71:
```swift
struct OpenTab: Identifiable {
    let id = UUID()
    let url: URL
    var content: String
    var originalContent: String
    var isModified: Bool = false
    var headings: [HeadingItem] = []
    var activeHeadingId: String?
    var scrollPosition: CGFloat = 0
    var blocks: [SemanticBlock] = []
    var activeBlockId: String?
    var blockCompilationState: [String: BlockCompilationState] = [:]

    var displayName: String { url.lastPathComponent }
    var fileType: FileType { FileType.from(url: url) }
    var isMarkdown: Bool { fileType == .markdown }
}

// FileType (L5-28) — based purely on file extension
enum FileType: String {
    case markdown, json, xml, yaml
    static func from(url: URL) -> FileType { ... }
}
```

**Tabs are identified by URL.** There is no `kind: TabKind` field. Mode switching inside the WebView is currently driven by `FileType` derived from extension (`.json` → tree view, `.md` → editor). For Recursive Insight we need either:

- **Option A (minimal):** Add `var kind: TabKind = .file` to `OpenTab`, default `.file` so all existing call sites continue working. New `case insight` carries an `InsightSession` reference.
- **Option B (sneaky):** Use a synthetic URL like `insight:///session-{uuid}` and dispatch on URL scheme. Slightly more fragile (file-system code paths might reject non-`file://` URLs).

**Recommended:** Option A. Add a thin enum:
```swift
enum TabKind { case file, insight(InsightSession) }
```
Keep `OpenTab.url` populated with a real (or placeholder) URL for backward compat. All ~30 sites that read `tab.url` continue to work for file tabs.

### Tab store API (single source of truth)

L234-303 — `WorkspaceTabsStore`:
```swift
@Published var openTabs: [OpenTab] = []
@Published var activeTabIndex: Int = -1
func appendTab(_ tab: OpenTab, activate: Bool = true)
func updateTab(at index: Int, _ mutate: (inout OpenTab) -> Void)
func updateActiveTab(_ mutate: (inout OpenTab) -> Void)
func removeTab(at index: Int)
```
Wrapped on `WorkspaceManager` (L377-385) as pass-through computed properties.

To open a new insight tab: `tabsStore.appendTab(OpenTab(url: ..., content: "", originalContent: "", kind: .insight(session)))`.

### `runAITool(named:)` — L1383-1398

```swift
func runAITool(named toolName: String, contentOverride: String? = nil) {
    guard let tool = WorkspaceAITool(rawValue: toolName) else { return }
    if tool.opensGraphCreator {
        presentGraphCreator(for: tool.rawValue)
        return
    }
    guard let engine = aiConsoleEngine,
          let prompt = aiPrompt(for: tool, contentOverride: contentOverride) else {
        return
    }
    engine.sendMessage(prompt)
    showAIConsole()
}
```
Two routing modes today: graph creator sheet OR a prompt sent to `aiConsoleEngine` (which runs Claude Code CLI in a side panel). Neither is what we want for Recursive Insight.

### `WorkspaceAITool` enum — L305-326

```swift
enum WorkspaceAITool: String {
    case architecture, dataflow, pipeline, deployment, sequence, er    // graph
    case critic, research, audit, codemap, fulldocs                    // analysis (sent to AIConsole)

    var opensGraphCreator: Bool { ... }
}
```

For Recursive Insight, **don't add a `.recursiveInsight` case here** — the existing routes (graph creator + AI Console) are wrong dispatches. Instead add a new dedicated method on `WorkspaceManager`:
```swift
func startRecursiveInsight() {
    guard let folderURL = rootNode?.url else { return }
    let mdFiles = scanMarkdownFiles(in: folderURL)
    guard !mdFiles.isEmpty else { return }
    let session = InsightSession(folderURL: folderURL, mdFiles: mdFiles, ...)
    let placeholderURL = folderURL.appendingPathComponent(".insight-\(UUID().uuidString)")
    let tab = OpenTab(url: placeholderURL, content: "", originalContent: "", kind: .insight(session))
    tabsStore.appendTab(tab)
    Task { await session.generateRoot() }
}
```

### `generateDocumentation(into:)` — L1428-1436

```swift
func generateDocumentation(into outputURL: URL) {
    guard let engine = aiConsoleEngine else { return }
    engine.sendMessage(documentationGenerationPrompt(outputDir: outputURL))
    showAIConsole()
}
```
Just delegates to AI Console. Not relevant to Recursive Insight directly, but confirms the existing pattern: heavy AI tasks go through `AIConsoleEngine` (Claude Code CLI), not direct API. We are deliberately departing from that pattern (user-spec L48 says "только Anthropic Messages API").

### `translateDocument(...)` — L1105-1191 — ★ KEY REFERENCE PATTERN

This is the closest existing analog to what Recursive Insight needs (progressive content accumulation in a new tab):

```swift
func translateDocument(markdown: String, targetLang: String) async {
    guard let provider = incrementalCompiler?.orchestrator.providerClient,
          let apiKey = provider.apiKeyValue else { return }

    let sourceTab = activeTabIndex >= 0 ... ? openTabs[activeTabIndex] : nil
    let newURL = sourceTab?.url.deletingLastPathComponent()
        .appendingPathComponent("\(sourceName)_\(targetLang.lowercased()).md") ?? ...

    // Create new tab IMMEDIATELY with placeholder
    let translatedTab = OpenTab(url: newURL,
        content: "# Translating to \(targetLang)...\n\nPlease wait...", originalContent: "")
    tabsStore.appendTab(translatedTab)

    let chunks = splitForTranslation(markdown, maxChars: 4000)
    var translatedParts: [String] = []
    let tabIndex = openTabs.count - 1

    for (i, chunk) in chunks.enumerated() {
        ...
        // Update tab content progressively
        tabsStore.updateTab(at: tabIndex) { tab in
            tab.content = translatedParts.joined(separator: "\n\n")
            tab.isModified = true
        }
    }
}
```
**Reuse pattern:** create tab → loop → mutate tab.content → SwiftUI re-renders. The fact that it works today proves WKWebView re-renders content correctly when `OpenTab.content` is reassigned via `updateTab`. Recursive Insight can follow the same loop, but instead of chunked completions we will receive SSE deltas and append after each text_delta event.

### File scanning patterns — three nearly identical sites

```swift
// L553-555 — excludeFolder
if let enumerator = fm.enumerator(at: folderURL,
    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension.lowercased() == "md" else { continue }
        ...
    }
}

// L930-934 — runStructuralIndex helper
guard let enumerator = fm.enumerator(at: rootURL,
    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
while let url = enumerator.nextObject() as? URL {
    guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
    ...
}

// L1564-1570 — analyzeAllFiles
guard let enumerator = fm.enumerator(at: folderURL,
    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
var mdFiles: [URL] = []
while let url = enumerator.nextObject() as? URL {
    if url.pathExtension.lowercased() == "md" { mdFiles.append(url) }
}
```
Recursive Insight should reuse this exact idiom (with the `.dde` exclude from the L934 variant). Suggest a small private helper:
```swift
private func scanMarkdownFiles(in folderURL: URL) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: folderURL,
        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
        files.append(url)
    }
    return files
}
```

### Close tab — handles dirty save prompt

L984-1005 — already handles modified tabs with NSAlert. For insight tabs we should set `isModified = false` always (they're ephemeral) so close skips the prompt. Need to check `kind` early:
```swift
func closeTab(at index: Int) {
    guard index >= 0 && index < openTabs.count else { return }
    if case .insight(let session) = openTabs[index].kind {
        session.cancel()  // stop active stream
        tabsStore.removeTab(at: index)
        return
    }
    if openTabs[index].isModified { ... existing logic ... }
}
```
This satisfies user-spec L41: "При закрытии вкладки дерево insight-узлов полностью освобождается из памяти" — by replacing `OpenTab` (which holds the strong ref to `InsightSession`), ARC frees the entire tree.

---

## 5. EditorView.swift + Resources/Editor/index.html — WebView host

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Views/EditorView.swift` (451 lines)
`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Resources/Editor/index.html` (3133 lines)

### How the WebView loads content

EditorView is **a single shared WKWebView** for the active tab — the HTML is loaded once with `webView.loadHTMLString(html, baseURL: editorResourceBaseURL)` (L127). On tab switch, only the JS state changes via bridge calls.

```swift
// L39-51 — updateNSView fires on tab change
func updateNSView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    if workspaceManager.activeTabIndex >= 0,
       workspaceManager.activeTabIndex < workspaceManager.openTabs.count {
        let tab = workspaceManager.openTabs[workspaceManager.activeTabIndex]
        coordinator.loadContentIfNeeded(tab.content, documentURL: tab.url)
    }
    coordinator.setTheme(themeManager.effectiveTheme)
}

// L194-227 — loadContentIfNeeded routes by FileType
func loadContentIfNeeded(_ markdown: String, documentURL: URL? = nil) {
    ...
    let fileType = documentURL.map { FileType.from(url: $0) } ?? .markdown
    if fileType != .markdown {
        bridge.loadStructuredContent(markdown, fileType: fileType.rawValue, into: webView) {}
        return
    }
    ...
    bridge.loadContent(resolved, into: webView) {}
}
```

**For Recursive Insight we need a third route here.** Suggested:
```swift
if case .insight(let session) = tab.kind {
    bridge.loadInsightContent(session.snapshot(), into: webView) {}
    return
}
```

### Existing modes inside index.html

```javascript
// L1021-1030 — global state
const state = {
    mode: 'source', // 'source' or 'preview'  ← extended to also include 'structured', 'structured-source'
    theme: ...,
    markdown: '',
    headings: [],
    activeHeadingId: null,
    isRendering: false,
    documentBaseURL: null,
    fileType: 'markdown', // 'markdown' | 'json' | 'xml' | 'yaml'
};
```

`state.mode` values used in code (L1679-1697, L2266-2282):
- `'source'` — raw textarea editor
- `'preview'` — rendered markdown
- `'structured'` — JSON/XML/YAML tree view
- `'structured-source'` — raw text for structured files

The pattern is well-established: a new `'insight'` mode would slot in cleanly. Window-level entry points (called from Swift via bridge):
```javascript
// L2245   window.setContent = function(markdown) { ... switchToPreview(); }
// L2257   window.setStructuredContent = function(content, fileType) { ... switchToStructuredView(); }
// L2542   window.setDocumentBase = function(baseURL) { ... }
// L2546   window.setTheme = function(theme) { ... }
```

For Recursive Insight, add:
```javascript
window.setInsightView = function(sessionId, markdown, breadcrumbs, deepDives) { ... }
window.appendInsightDelta = function(sessionId, deltaText) { ... }
window.setInsightDeepDives = function(sessionId, deepDives) { ... }
window.showInsightLoading = function(sessionId, msg) { ... }
```
And paired Swift-side bridge methods.

### Existing Mermaid pipeline (key for inline streaming Mermaid)

```javascript
// L1098-1099 — init
mermaid.initialize({ startOnLoad: false, theme: state.theme === 'dark' ? 'dark' : 'default' });

// L1202-1230 — convert markdown code fences to mermaid divs after each renderMarkdown()
const mermaidBlocks = DOM.rendered.querySelectorAll('pre code.language-mermaid');
mermaidBlocks.forEach((code, idx) => {
    const pre = code.parentElement;
    const mermaidSource = code.textContent;
    if (mermaidSource.includes('%%INTERACTIVE')) {
        // D3 canvas
        ...
    } else {
        // Standard SVG
        const div = document.createElement('div');
        div.className = 'mermaid';
        div.textContent = mermaidSource;
        div.setAttribute('data-source', mermaidSource);
        pre.replaceWith(div);
    }
});

// L1241-1254 — actual mermaid.run() call
if (typeof mermaid !== 'undefined') {
    setTimeout(() => {
        try {
            const nodes = DOM.rendered.querySelectorAll('.mermaid');
            if (nodes.length > 0) {
                mermaid.run({ nodes: nodes });
            }
        } catch(e) {
            try { mermaid.contentLoaded(); } catch(e2) {}
        }
    }, 0);
}
```
Currently no try/catch wraps `mermaid.run` per-block — failure of one block in `.run({nodes})` may abort the batch. For Recursive Insight (where LLM may generate invalid Mermaid mid-stream), we should render insight-mode Mermaid blocks **one at a time** with per-block try/catch and a fallback "show raw code on error" UI.

### Insight rendering: re-use markdown-it pipeline

The `md.render(contentMd)` call at L1153 is reusable as-is. For Recursive Insight, the JS side just needs:
1. A new container DOM (split-pane: center markdown + right deep-dive list).
2. A function that calls `md.render(...)` then runs the same mermaid post-processing as L1202+.
3. A debounced re-render on each `appendInsightDelta` (~150ms per user-spec L55).

---

## 6. WebViewBridge.swift — Swift↔JS messaging

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Bridge/WebViewBridge.swift` (334 lines)

### Direction: JS → Swift (postMessage)

```swift
// L83-117 — userContentController(_:didReceive:)
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let dict = message.body as? [String: Any],
          let messageType = dict["type"] as? String else { return }
    let payload = dict["payload"]
    ...
    handleMessage(type: messageType, data: data)
}
```
JS sends via `window.webkit.messageHandlers.bridge.postMessage({type: "...", payload: {...}})`. The handler is registered in EditorView L15: `userController.add(bridge, name: "bridge")`.

Existing JS → Swift message types (L121-191 dispatch):
- `contentChanged`, `headingsUpdated`, `scrollPosition`, `ready`, `linkClicked`, `blocksChanged`, `textChanged`, `saveRequested`, `translateRequested`, `selectionAction`, `refreshRequested`, `aiTool`, `generateGraph`.

For Recursive Insight, **add new message types**:
- `insightDeepDiveClicked` — payload `{sessionId, topicIndex}` → Swift creates child node + starts streaming.
- `insightSaveRequested` — payload `{sessionId}` → Swift opens NSSavePanel.
- `insightBreadcrumbClicked` — payload `{sessionId, nodePath}` → Swift switches view to existing in-memory node (no LLM call).
- `insightUpClicked` — payload `{sessionId}` → Swift returns to parent.

### Direction: Swift → JS (evaluateJavaScript)

```swift
// L198-217 — loadContent
func loadContent(_ markdown: String, into webView: WKWebView, completion: @escaping () -> Void) {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: [markdown], options: []),
          let jsonArrayString = String(data: jsonData, encoding: .utf8) else { ... }
    let jsonString = String(jsonArrayString.dropFirst().dropLast())
    let js = "window.setContent(\(jsonString))"
    webView.evaluateJavaScript(js) { _, error in ... }
}
```
The `[markdown]` array trick safely encodes a string for embedding in JS source. **This idiom is critical** — bare strings via `JSONSerialization.data(withJSONObject:)` fail with `NSInvalidArgumentException`. Reuse it for every Swift→JS string payload.

### Streaming-style communication today: NONE

There is no existing pattern for high-frequency Swift→JS push (e.g., per-token deltas). All current `evaluateJavaScript` calls are one-shot per significant state change.

For Recursive Insight, evaluating `window.appendInsightDelta(sessionId, deltaText)` per SSE chunk is fine performance-wise (`evaluateJavaScript` is ~0.1ms per call on M1). But to satisfy user-spec L55 (debounce re-render to ~150ms), the **debounce should live on the JS side** — Swift fires every delta, JS coalesces into a single `renderMarkdown()` call.

### Bridge delegate protocol — L319-334

Add new delegate methods for the four insight messages above. Implement in `EditorView.Coordinator` extension (L319-445), forwarding to `WorkspaceManager.startInsightDeepDive(sessionId:topicIndex:)` etc.

### Implication

Bridge is already a generic message bus. No structural change required — just add new message types and JS entry-point functions. Mostly additive work.

---

## 7. CacheManager.swift — caching strategy

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/CacheManager.swift` (51 lines, very small)

```swift
class CacheManager {
    private let cacheDir: URL  // {workspace}/.dde/cache/provider_responses

    func loadCachedResponse(inputHash: String) -> Data?
    func saveCachedResponse(inputHash: String, data: Data)
    func hasCachedResponse(inputHash: String) -> Bool
    func evict(keepLast count: Int = 1000)
}
```
Keying is **content-hash based** (FNV-1a in `AIOrchestrator.fnv1aHash` L395-402). Same input → same cache file.

### For Recursive Insight: BYPASS

Two reasons:
1. The user-spec (L42-46) says "дерево insight-узлов живёт только в JS-памяти WKWebView" and "каждый сеанс анализа уникален". So caching root summaries between sessions has no user-facing benefit (the tree is ephemeral).
2. Streaming responses don't fit the existing JSON-blob cache shape (`Data` of an encoded `BlockExtractionResult`).

**Recommendation:** Recursive Insight does not write to or read from `CacheManager`. The session is fully in-memory; closing tab discards the tree. If we later want cross-session caching of common deep-dives, we can add it as a separate `InsightCache` keyed by `(folderHash, breadcrumbPath)` — but out of scope per user-spec.

---

## 8. SemanticDatabase.swift — DB schema

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/SemanticDatabase.swift` (1406 lines)

Confirmed: **NO new tables required.** The user-spec explicitly forbids persistence (L42-46). Recursive Insight lives entirely in JS memory.

For reference, the `artifacts` table that GraphRAG uses (L443-453):
```sql
CREATE TABLE IF NOT EXISTS artifacts (
    artifact_id TEXT PRIMARY KEY,
    module_id TEXT,
    kind TEXT NOT NULL,    -- e.g. "deep_research", "summary"
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    model_used TEXT
)
```
**We will NOT use this table.** Recursive Insight session state is held by `InsightSession` (Swift class) for the lifetime of its tab.

The `ai_jobs` table (L263-282) is also untouched — we bypass `AIOrchestrator` (see §2).

---

## 9. File scanning utilities

Already documented in §4. Pattern is `FileManager.enumerator(at:options: [.skipsHiddenFiles])` + `pathExtension == "md"` filter. The `.dde` exclusion is important to avoid reading our own cache. Three near-duplicate copies exist; recommend extracting `scanMarkdownFiles(in:)` helper as part of this feature.

---

## 10. Tab struct/enum — definitive answer

Already covered in §4. **Recap:**

- File: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/DocumentState.swift` L42.
- `OpenTab` is a `struct`. No `kind` field today.
- 12 readers of `tab.url`/`tab.content`/etc. across:
  - `WorkspaceManager.swift` (multiple sites)
  - `Views/EditorView.swift` (L43-46)
  - `Views/TabBarView.swift` (L19-86)
  - `Views/CompilePanelView.swift` L226
  - `Views/DiagnosticsBarView.swift` L84

**Adding `var kind: TabKind = .file`** with a default value preserves source compatibility for all existing call sites. No mass rewrite needed. Each site that NEEDS to differentiate (TabBarView display, EditorView routing, closeTab) explicitly switches on `kind`.

---

## 11. ContentView.swift — menu wiring

`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Views/ContentView.swift` L114-134:

```swift
Menu {
    Section("Diagrams") {
        Button("🏗 System Architecture") { workspaceManager.runAITool(named: "architecture") }
        ... 5 more ...
    }
    Section("Analysis") {
        Button("🔍 Constructive Critic") { workspaceManager.runAITool(named: "critic") }
        Button("🌐 Deep Research") { workspaceManager.runAITool(named: "research") }
        Button("📋 Full Codebase Audit") { workspaceManager.runAITool(named: "audit") }
        Button("🗂 Code Structure Map") { workspaceManager.runAITool(named: "codemap") }
        Button("📚 Generate Full Documentation") { workspaceManager.runAITool(named: "fulldocs") }
    }
} label: {
    Image(systemName: "wand.and.stars")
}
.help("AI Tools")
```

Insertion point: add a new Button to the `Section("Analysis")`:
```swift
Button("🧭 Recursive Insight") {
    workspaceManager.startRecursiveInsight()
}
.disabled(workspaceManager.rootNode == nil ||
          workspaceManager.rootNode?.url.hasDirectoryPath != true ||
          !workspaceManager.hasMarkdownFiles)
```

Note: `runAITool(named: "...")` should NOT be reused (see §4, the runAITool path goes to AI Console which is wrong). New direct method `startRecursiveInsight()`.

The disabled-state predicate needs a small `hasMarkdownFiles` computed property on `WorkspaceManager` that checks if the file tree has any `.md` files (or scan eagerly with the helper from §9).

---

## 12. Tests — NONE exist (major risk)

```bash
$ ls /Users/boris/Documents/Claude/Projects/MarkDV/MarkView/Tests/
# (empty)
```
- `Tests/` folder exists but is empty.
- `project.yml` defines only **one target** (`MarkView` application); no `MarkViewTests` target.
- `install.sh`: `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Release archive ...` — never invokes `xcodebuild test`.
- No `XCTest` imports anywhere: `grep -rn "import XCTest" MarkView/` returns nothing.

### Implication for Recursive Insight

The user-spec demands unit + integration tests (L73-89):
- "SSE-парсер Anthropic собирает текст из мок-потока" (xcodebuild test)
- "InsightSession lifecycle ... добавляет child, навигация up/down работает" (xcodebuild test)
- "WebViewBridge передаёт streaming chunks в JS" (xcodebuild test integration)

**We must set up the test target as part of this feature.** Required steps:

1. Edit `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/project.yml` to add a `MarkViewTests` target:
   ```yaml
   MarkViewTests:
     type: bundle.unit-test
     platform: macOS
     sources:
       - path: Tests
     dependencies:
       - target: MarkView
   ```
2. Run `xcodegen` to regenerate `MarkView.xcodeproj`.
3. Add a test scheme so `xcodebuild test -scheme MarkView` (or `MarkViewTests`) works.
4. Create `Tests/InsightSSEParserTests.swift`, `Tests/InsightSessionTests.swift`.

This is a real-but-bounded scope expansion: ~30-60 min one-time, then standard XCTest authoring. **Important:** do NOT skip it — the codebase has no other tests, so this feature setting up the test infrastructure will benefit all future features.

---

## Risks summary

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | First SSE streaming code in the codebase (no prior art for `URLSession.bytes(for:)`) | Medium | Isolate in `AIProviderClient.streamCompletion(...)`. Unit-test parser with mock chunked streams. |
| 2 | `OpenTab` has no `kind` field; ~10+ call sites read `tab.url` blindly | Low | Default `kind: .file`. Existing call sites unaffected. Only EditorView/TabBarView/closeTab branch on it. |
| 3 | `AIOrchestrator` is hard-coupled to `BlockExtractionResult` — cannot host streaming jobs | Low | Bypass entirely. New `InsightSession` uses `providerClient` directly, mirroring `translateDocument` pattern (L1105). |
| 4 | `GraphRAG.deepResearch()` uses module metadata only (not file bodies) | Medium | Don't reuse the function as-is. Use only `detectCommunities()` + `communities` for clustering, then read file bodies ourselves and stream the reduce step. |
| 5 | Mermaid mid-stream may render invalid blocks and abort the batch `mermaid.run({nodes})` call (L1247) | Medium | In insight mode, render Mermaid blocks **one-at-a-time** in try/catch; on error show raw fenced code with error label. |
| 6 | `---DEEP-DIVES---` marker may collide with markdown horizontal rules | Low | Use full marker `\n\n---DEEP-DIVES---\n` with surrounding newlines. Parse only the **last** occurrence in the buffer. |
| 7 | **No XCTest target exists in the project** | High | Create `MarkViewTests` target via `project.yml`, regenerate Xcode project. One-time infrastructure cost ~30-60 min. |
| 8 | WebView load model is single-shared-WKWebView; switching between editor and insight requires JS-side mode switch (mirrors `state.mode`) | Low | Follow existing precedent (`'structured'` mode). Add `'insight'` mode to `state.mode`. |
| 9 | `evaluateJavaScript` per token may flood main thread | Low | JS-side debounce (150ms re-render); Swift just appends to a JS string buffer per delta. |
| 10 | macOS sandbox might block .md reads outside the user-selected folder | Low | Sandbox is OFF (per user-spec L52, confirmed by entitlements file). Folder access already granted via `openFolder` → `NSOpenPanel`. |

---

## Concrete work plan derived from research

1. **Test infra** — Add `MarkViewTests` target to `project.yml`, regenerate.
2. **AIProviderClient.swift** — Add `streamCompletion(systemPrompt:userMessage:onDelta:)` method using `URLSession.bytes(for:)` and SSE parser. Add `case streamingError(String)` to `AIProviderError`.
3. **DocumentState.swift** — Add `enum TabKind { case file; case insight(InsightSession) }`. Add `var kind: TabKind = .file` to `OpenTab`.
4. **InsightSession.swift** (NEW, `MarkView/Models/`) — Class managing the in-memory tree of `InsightNode` items. Owns reference to `AIProviderClient`. Methods: `generateRoot()`, `expand(deepDiveIndex:)`, `navigateTo(nodeId:)`, `up()`, `cancel()`. Holds `@Published var currentNode: InsightNode` and `@Published var streamingBuffer: String` for the JS bridge.
5. **WorkspaceManager.swift** — Add `startRecursiveInsight()` method (~30 lines), helper `scanMarkdownFiles(in:)`, branch in `closeTab` for insight kind. Add `hasMarkdownFiles: Bool` computed property for menu enabled-state.
6. **ContentView.swift** — Add `Button("🧭 Recursive Insight")` to the Analysis Section (L124-130).
7. **WebViewBridge.swift** — Add 4 new JS→Swift message cases (`insightDeepDiveClicked`, `insightSaveRequested`, `insightBreadcrumbClicked`, `insightUpClicked`) and 4 new Swift→JS commands (`setInsightView`, `appendInsightDelta`, `setInsightDeepDives`, `showInsightLoading`). Extend delegate protocol.
8. **EditorView.swift** — In `loadContentIfNeeded`, branch on `tab.kind == .insight(...)` and route to `bridge.setInsightView(...)`. Subscribe to session's `streamingBuffer` for delta forwarding.
9. **index.html** — Add `state.mode = 'insight'` branch. New DOM container with split-pane (center markdown + right deep-dive list + top breadcrumbs + bottom Save/Up buttons). Reuse `md.render()` and existing mermaid pipeline (with per-block try/catch). Implement debounced re-render (~150ms).
10. **Tests** — `Tests/InsightSSEParserTests.swift` (mock SSE byte streams), `Tests/InsightSessionTests.swift` (tree lifecycle).

---

## Files touched (preview)

Modified:
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/project.yml`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/AIProviderClient.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/DocumentState.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/WorkspaceManager.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Views/ContentView.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Views/EditorView.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Bridge/WebViewBridge.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Resources/Editor/index.html`

New:
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/InsightSession.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/Tests/InsightSSEParserTests.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/Tests/InsightSessionTests.swift`

Untouched (confirmed):
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/AIOrchestrator.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/CacheManager.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/SemanticDatabase.swift`
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/GraphRAG.swift` (read-only use of `detectCommunities()` + `communities`)
