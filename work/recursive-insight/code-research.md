---
created: 2026-04-30
status: research
type: code-research
feature: recursive-insight-v2
---

# Code Research: Recursive Insight v2 ("Insight Web")

Source-of-truth survey of the v1 implementation that v2 will replace, the
integration seams that v2 must keep, and the new pieces (iframe sandbox,
postMessage protocol, disk cache, ZIP export, pre-bundled lib distribution)
that v2 introduces. All paths are absolute. v1 archive at
`/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/work/recursive-insight-v1/`
(read for context; the code itself is being deleted, not extended).

---

## 1. WKWebView host context and sandbox semantics

### Project sandbox posture
- `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/MarkView.entitlements` L7-8:
  `com.apple.security.app-sandbox = false`. Comment: *"App Sandbox OFF — required for `Process()` to launch claude/codex CLI tools."* Same in `MarkViewDebug.entitlements`.
- v2 inherits this — `Process` + `/usr/bin/zip` for ZIP export will work; arbitrary file writes for `<workspace>/.insight-cache/` and ZIP export will work.

### WKWebView configuration today (EditorView.swift L10-38)
```swift
let config = WKWebViewConfiguration()
let userController = WKUserContentController()
userController.add(bridge, name: "bridge")  // window.webkit.messageHandlers.bridge
config.userContentController = userController
config.preferences.setValue(true, forKey: "developerExtrasEnabled")
let webView = WKWebView(frame: .zero, configuration: config)
webView.navigationDelegate = context.coordinator
…
// HTML loaded once, theme inlined, then loadHTMLString
```
**Implications for v2 nested iframe:**
- WKWebView fully supports HTML5 `<iframe sandbox="…">`; the nested document is a separate Document inside the parent's content process.
- `WKUserContentController.add(_:name:)` injects `window.webkit.messageHandlers.<name>` into **every** frame in the WebView **by default**. Scripts inside an iframe can call `window.webkit.messageHandlers.bridge.postMessage(...)` UNLESS:
  - The iframe is loaded with `sandbox="allow-scripts"` WITHOUT `allow-same-origin`, AND
  - We register the message handler with `contentWorld:` plus `forMainFrameOnly: true` (not directly available on `add(_:name:)`; we need `addScriptMessageHandler(_:contentWorld:name:)` with a custom WKContentWorld).
- The CLEANEST defense — and what v2 must do — is: when the iframe srcdoc is rendered with `sandbox="allow-scripts"` (no `allow-same-origin`), the iframe's origin becomes the opaque "null" origin. `window.webkit.messageHandlers.bridge` is still injected by default but messages from a null-origin iframe are still delivered; the only reliable barrier is **iframe code cannot reach the parent window's JS context** (cross-origin DOM block).
- **Therefore: do NOT rely on iframe being "unable to call bridge".** Instead, gate every new postMessage in the existing `WebViewBridge.handleMessage` switch (WebViewBridge.swift L121-222) — unknown types are silently dropped (current `default: NSLog(...)`). Add explicit allowlist comment + reject any iframe-origin postMessage that doesn't match the v2 protocol.
- The CORRECT pattern from the spec: iframe → `window.parent.postMessage(...)` (HTML5 `MessageEvent`, not WebKit bridge). Parent page (the host index.html) listens via `window.addEventListener('message', e => …)`, validates, then forwards selected messages to Swift via the existing bridge. This keeps Swift's bridge completely off-limits to the iframe's JS by relying on standard cross-origin DOM rules — sandbox=allow-scripts WITHOUT allow-same-origin makes `window.parent.webkit` inaccessible from the iframe's null origin.

### Risk: `WKContentRuleList` / WKUserScript scope
- The project does NOT use `WKContentRuleList` (verified: no references). v2 introduces no rules either.
- The project does NOT use `WKUserScript` (verified: no `addUserScript` calls; only `add(message-handler:)`). So no script bleed risk into iframes. **Safe.**

### `forMainFrameOnly` consideration
- `WKScriptMessageHandler` registration via `add(_:name:)` defaults to `forMainFrameOnly: true` in older docs but historical behavior has been inconsistent across macOS versions. To be safe in v2 we should use the modern `addScriptMessageHandler(_:contentWorld:name:)` form with `WKContentWorld.page` AND verify by attempting `window.webkit.messageHandlers.bridge` inside the sandboxed iframe at smoke-test time. If accessible from iframe → fall back to: (a) parent-only window.postMessage relay (already the design), AND (b) a Swift-side allowlist that ALSO checks `message.frameInfo.isMainFrame` to drop iframe messages outright.

**ACTION ITEMS for tech-spec:**
1. Verify `WKScriptMessage.frameInfo.isMainFrame` in v2 — drop any handler call where `false`.
2. Add a Swift-side allowlist that validates incoming bridge messages against the 5 allowed types from inside the parent only.
3. Test on the user's actual macOS version (Darwin 25.4) early.

---

## 2. v1 code being REPLACED

### 2.1 InsightSession.swift (full rewrite)
Path: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/InsightSession.swift` (1073 lines).

**Public surface to preserve (so the rest of the codebase doesn't churn):**
- `@MainActor final class InsightSession: ObservableObject, Identifiable` — keep class shape.
- `let id = UUID()` — keep, used by `findInsightSession(sessionId:)`.
- `init(folderURL: URL, mdFiles: [URL], providerClient: AIProviderClient, graphRAG: GraphRAG?)` — keep, called by `WorkspaceManager.startRecursiveInsight()` L1402-1407.
- `func generateRoot() async`, `func cancel()`, `func currentNode() -> InsightNode?` — keep names; semantics evolve (v2's "node" wraps an HTML document, not a markdown body).
- `func snapshot() -> InsightViewSnapshot` — KEEP NAME but change shape (carries skeleton JSON + per-section status + breadcrumbs, not markdown body + deepDives).

**v1 internals being deleted entirely:**
- L552 `bodyPortion(of:)` + L873 `parseMarker(_:)` — `---DEEP-DIVES---` marker pipeline is gone.
- L915-934 `systemPromptDataIsolation` (markdown-output prompt) — replaced by Phase 1 JSON-skeleton + Phase 2 HTML-content prompts.
- L947-970 `buildRootUserMessage` / L974-1012 `buildTopicUserMessage` — keep XML-envelope safe-wrap idea, change output instructions.
- L1056-1072 `escapeXMLEnvelopeBreakout` — KEEP (still needed for prompt-injection defense in any `<file>` envelope going to LLM).
- L723-761 `validateScopeHint` — KEEP (deep-dive selection still resolves to a scope_hint set of files).
- L773-829 `rankByPathDistance`/`commonAncestorComponents`/`pathComponentDistance` — KEEP (same reasoning).
- L836-866 `enforceSessionMemoryCap` — KEEP CONCEPT but cap moves from "in-memory rawBuffer per node" to "per-node HTML byte size" (per-node 2 MB cap per user-spec) and total session cap on `.insight-cache/<session-uuid>/`.
- L142 `retryHistory` + L368-480 `retryCurrent` — KEEP retry throttle (3/60s/node).

**InsightNode (L54-96) shape changes:**
- `var rawBuffer: String` (markdown stream) → `var html: String` (sanitized HTML doc) AND `var skeleton: NodeSkeleton` (the Phase 1 JSON).
- `var markdownBody: String`, `var deepDives: [DeepDiveTopic]` → DELETE; deep-dive metadata moves into the skeleton JSON.
- `let scope: NodeScope` — KEEP (still `.folderRoot` / `.topic(label, hint, files)`).
- `var status: Status { .pending | .streaming | .ready | .failed }` — KEEP, but extend with section-level status when sections stream in parallel: `var sectionStatus: [String: Status]`.

### 2.2 GraphRAG.mapReduceForFolder (KEEP STREAMING, REWRITE PROMPTS)
Path: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Models/GraphRAG.swift` L233-538.

**STAYS unchanged:**
- `detectCommunities()` (L28-103) — clustering primitive.
- `mapReduceMaxFiles = 500` (L199) hard cap.
- File enumeration + 50 KB per-file truncation (L341-347).
- 200 KB per-community chunking (L379-395).
- `withThrowingTaskGroup` parallel map with `mapReduceMaxConcurrent = 5` (L474-500).
- `escapeXMLEnvelopeBreakout` (L554-589).
- XML attribute percent-encoding (L212-216 `xmlAttrSafeCharacters`).
- All path-symlink containment checks (L301-329).
- Reduce step uses `provider.streamCompletion(...)` (L531-537).

**CHANGES:**
- The reduce-step `reduceSystemPrompt` (L515-517) currently asks the model to merge partial summaries into a coherent **markdown** answer. v2 needs TWO modes:
  - **Phase 1 reduce:** ask the model to emit ONLY a JSON skeleton describing the page structure (sections + types + deep-dive anchors). Strict JSON schema. Streaming is wasted (skeleton is ~1-2 KB total) — could even be a non-streaming `URLSession.shared.data(for:)` call for lower latency.
  - **Phase 2 content:** for each skeleton section, ask the model to emit HTML/JS for that section. Either ONE call with section markers (cheaper, but interleaved sections are harder to route as deltas) OR N parallel calls (truly parallel section fill; matches user-spec "Несколько секций могут заполняться параллельно"). User-spec L31 explicitly endorses parallel section fill.
- The map step (L419-421 `mapSystemPrompt`) is unaffected — it still produces prose summaries that feed the reduce step. Map output stays plain text per cluster.

**Decision needed for tech-spec:** single-stream-with-section-tags vs N-parallel-streams for Phase 2. Cost: parallel = N × prompt overhead; single = serial render of sections (one section can't start until previous's tag closes). User-spec L31 says parallel — go parallel.

### 2.3 Resources/Editor/index.html (insight-mode rewrite)
Path: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Resources/Editor/index.html` (3819 lines total).

**INSIGHT-MODE LINE MAP (lines that are insight-only and must be deleted/rewritten in v2):**

| Range | Content | v2 disposition |
|-------|---------|----------------|
| L8-22 | Comment block + CSP header (currently weakened: `script-src https://cdn.jsdelivr.net`). Insight intent listed in comment. | KEEP comment; CSP needs update — v2 iframe is sandboxed so script-src doesn't help inside the iframe; parent CSP can stay for the host page. |
| L851-1018 | `.insight-container`, `.insight-breadcrumbs`, `.insight-body`, `.insight-center`, `.insight-right`, `.insight-deep-dive-*`, `.insight-button-row`, `.insight-mermaid-error` — all insight-mode CSS | REWRITE: new layout (no right pane). Keep top-level `.insight-container`, breadcrumbs bar, status bar, single iframe slot. |
| L1113-1132 | DOM template: `#insight-container > #insight-breadcrumbs + #insight-body(#insight-center + #insight-right(#insight-error-banner + deep-dives-list)) + #insight-button-row` | REWRITE: replace `#insight-body` with a single `#insight-iframe-host`. Remove right pane entirely. |
| L1242-1273 | `state.insightSessionId/insightBufferText/insightDeepDives/insightBreadcrumbs/insightIsStreaming/insightLastError/insightRenderTimer` + `DOM.insight*` references | REWRITE: state replaced by `state.insightSessionUuid`, `state.insightCurrentNodeUuid`, `state.insightIframe`, `state.insightSkeleton`, `state.insightSectionsFilled` (Set). |
| L1909-1910, L1916-1917, L1930-1931, L2503, L2517, L2769-2770 | Mode-switch guards (`if (state.mode === 'insight') return;`) and `leaveInsightView()` calls scattered across other-mode handlers | KEEP — they prevent other modes from clobbering insight; the same guards apply unchanged in v2. |
| L2783-3225 | The whole `RECURSIVE INSIGHT MODE` block: `insightMd` markdown-it instance (L2791-2870), `INSIGHT_MARKER` parser (L2885-2918), `processInsightMermaidBlocks` (L2921-2960), `renderInsight` (L2962-2997), `renderInsightDeepDivesFromArray` (L2999-3031), `renderInsightBreadcrumbs` (L3033-3059), `setInsightErrorBanner` (L3061-3074), `scheduleInsightRender` (L3076-3082), `switchToInsightView` (L3085-3109), `leaveInsightView` (L3111-3120), `window.loadInsightView/appendInsightDelta/setInsightDeepDives/showInsightLoading/setInsightError` (L3123-3203), `initInsightButtons` (L3205-3222) | DELETE WHOLESALE. Replace with iframe-driven flow. |

**v2 host-page JS additions (in same insight-mode block range):**
- `window.loadInsightSkeleton(jsonSkeleton)` — receive Phase 1 skeleton from Swift, build iframe srcdoc with placeholder containers + skeleton-loader CSS animations + pre-bundled lib `<script>` tags + the skeleton JSON serialized as `window.__SKELETON__`.
- `window.appendInsightSection(sessionId, nodeId, sectionId, htmlChunk)` — forward Phase 2 stream chunks to the iframe via `iframe.contentWindow.postMessage({type:'sectionChunk', sectionId, chunk}, '*')`.
- `window.finalizeInsightSection(sessionId, nodeId, sectionId)` — notify iframe section is complete (so it can stop spinner / run mermaid render etc).
- `window.loadInsightNode(sessionId, nodeId, fullHtml)` — for cached navigation: replace iframe srcdoc atomically with the cached full HTML.
- `window.setInsightStatus(text)` — update bottom status bar.
- `window.setInsightBreadcrumbs(crumbsArray)` — render top breadcrumbs bar.
- `window.addEventListener('message', …)` parent-side allowlist — accept ONLY: `iframeReady`, `deepDiveClicked` (payload: `{nodeUuid, sectionId, deepDiveIndex}`), `breadcrumbClicked` (payload: `{nodeUuid}`), `requestSave`, `requestUp`. Drop everything else with `console.warn`.

**Pre-bundled libs already on disk:**
- `vendor/js/markdown-it.min.js` 101 KB
- `vendor/js/markdown-it-footnote.min.js` 5.7 KB
- `vendor/js/markdown-it-task-lists.min.js` 2.6 KB
- `vendor/js/markdown-it-container.min.js` 1.6 KB
- `vendor/js/mermaid.min.js` **2.8 MB** (large)
- `vendor/js/katex.min.js` 271 KB
- `vendor/js/auto-render.min.js` 3.4 KB
- `vendor/js/prism.min.js` 19 KB + per-language files ~1-6 KB each
- `vendor/css/katex.min.css`, `prism-okaidia.min.css`, `prism-line-numbers.css`, `prism-diff-highlight.css`
- **NO Chart.js currently present.** v2 must add it (download a min build, ~250 KB) and place it in `vendor/js/chart.min.js`.

**Lib distribution strategy for iframe srcdoc (key tradeoff):**
- Sandbox iframe (no allow-same-origin) is a separate "null" origin — it CANNOT load `<script src="vendor/js/...">` against the parent's `editorResourceBaseURL`. The src would resolve relative to the iframe's `about:srcdoc` origin and fail.
- Two viable strategies:
  - **A. Inline minified libs into srcdoc.** Each iframe srcdoc carries ~1 MB inline (mermaid alone is 2.8 MB; need mini-mermaid build OR drop mermaid for some node types). Per-node cap of 2 MB requires omitting mermaid from nodes that don't need it, OR using a leaner diagram lib.
  - **B. Convert each lib to a `blob:` URL** in the parent and include that URL in the srcdoc. `blob:` URLs created in the parent context are accessible from the sandboxed iframe via `<script src="blob:...">`. Single copy in memory, all iframes reference. Verified pattern in WebKit; confirm at smoke test.
- **Recommended: B (blob URLs).** Parent reads `vendor/js/*.js` once (already done by index.html load), creates `Blob([…])` + `URL.createObjectURL(blob)`, and writes the resulting URLs into srcdoc. ZIP export uses strategy A-equivalent: copy actual `.js` files into `_assets/` and rewrite `<script src="_assets/mermaid.js">`.

### 2.4 WebViewBridge.swift (rewrite insight messaging)
Path: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Bridge/WebViewBridge.swift` (480 lines).

**STAYS unchanged:**
- `WKScriptMessageHandler` plumbing (L83-117).
- `BridgeMessage` / `AnyCodable` types (L13-75).
- `loadContent`, `loadStructuredContent` (L244-282).
- All non-insight bridge methods (L122-188 cases + their delegate methods).
- `encodeStringForJS` array-wrap idiom (L232-239) — REUSE for v2 calls.

**REPLACE entirely (L190-217 dispatch + L284-375 commands + L474-479 delegate methods):**

| v1 method | v2 replacement |
|-----------|----------------|
| `loadInsightView(snapshot:)` | `loadInsightSkeleton(sessionId:nodeId:skeletonJSON:into:)` |
| `appendInsightDelta(sessionId:text:)` | `appendInsightSectionChunk(sessionId:nodeId:sectionId:chunk:into:)` |
| `setInsightDeepDives(sessionId:topics:)` | DELETE — deep-dive buttons live inside section HTML |
| `showInsightLoading(...)` | `setInsightStatus(text:into:)` (bottom bar text only) |
| `setInsightError(...)` | KEEP same shape — error still surfaces top-of-iframe-host |
| (new) | `finalizeInsightSection(sessionId:nodeId:sectionId:into:)` |
| (new) | `loadCachedInsightNode(sessionId:nodeId:fullHtml:into:)` |
| (new) | `setInsightBreadcrumbs(sessionId:crumbsJSON:into:)` |

**JS→Swift message types — REPLACE the 5 v1 cases (L192-217):**

| v1 message | v2 message | Payload |
|-----------|------------|---------|
| `insightDeepDiveClicked` | `insightDeepDiveClicked` | `{sessionId, nodeId, sourceSectionId, deepDiveIndex}` |
| `insightSaveRequested` | `insightSaveRequested` (alias `requestSave`) | `{sessionId, nodeId}` |
| `insightBreadcrumbClicked` | `insightBreadcrumbClicked` | `{sessionId, nodeId}` (target uuid) |
| `insightUpClicked` | `insightUpClicked` (alias `requestUp`) | `{sessionId}` |
| `insightRetryRequested` | `insightRetryRequested` | `{sessionId, nodeId}` |
| (new) | `insightIframeReady` | `{sessionId, nodeId}` (timing/timeout signal) |
| (new) | `insightExportArchiveRequested` | `{sessionId}` (top toolbar button) |

**Delegate protocol changes (L457-479):**
- KEEP signatures of `didRequestInsightDeepDive/Save/Breadcrumb/Up/Retry`. They map cleanly: WorkspaceManager already has matching forwarders (L1458-1515).
- ADD: `didRequestInsightIframeReady(sessionId:nodeId:)` and `didRequestInsightExportArchive(sessionId:)`.

### 2.5 EditorView.swift (Combine subscriptions stay, bridge calls change)
Path: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Views/EditorView.swift` L80-372.

**STAYS:**
- `routeInsight(session:webView:)` skeleton (L280-372) — same idea: drop old subs on session switch, paint snapshot, subscribe to streaming.
- `currentInsightSessionId`, `lastForwardedLength` ivars (L86-96) — same purpose.
- `insightCancellables = Set<AnyCancellable>()` cleanup pattern.
- All `case .insight` branches in `loadContentIfNeeded` (L234-248), `bridgeSaveRequested` (L535-547), `bridgeRefreshRequested` (L590-599) — same kind-discriminator logic.

**CHANGES:**
- `bridge.loadInsightView(snapshot:)` (L298) → `bridge.loadInsightSkeleton(...)` first, then per-section `bridge.appendInsightSectionChunk(...)` driven by NEW `@Published var sectionChunks: [(sectionId: String, chunk: String)]` on InsightSession (or similar PassthroughSubject).
- `session.$streamingBuffer` subscription (L303-325) → REPLACE with `session.sectionChunkPublisher` (PassthroughSubject) — incremental delivery is naturally per-section now, no need for `lastForwardedLength` length-diff trick.
- `session.$currentNodeId` subscription (L338-352) → KEEP shape; on node change call `bridge.loadInsightSkeleton(...)` (or `loadCachedInsightNode(...)` if the new node has a complete cached html).
- `session.$lastError` subscription (L357-371) → KEEP unchanged.

**NEW subscription needed:**
- `session.$breadcrumbs` (or recompute from `currentNodeId` change) → `bridge.setInsightBreadcrumbs(...)`.
- `session.$status` (Phase 1/2 progress for status bar) → `bridge.setInsightStatus(...)`.

### 2.6 ContentView.swift (no change)
Path: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/MarkView/Views/ContentView.swift` L130-131:
```swift
Button("🧭 Recursive Insight") {
    workspaceManager.startRecursiveInsight()
}
```
KEEP as-is. Same entry point, same enabled-state predicate.

---

## 3. v1 code that STAYS (integration seams to keep)

| Component | Path | Reason |
|-----------|------|--------|
| `enum TabKind { case file; case insight(InsightSession) }` | DocumentState.swift L45-48 | v2 still needs the discriminator. KEEP UNCHANGED. |
| `WorkspaceManager.startRecursiveInsight()` | WorkspaceManager.swift L1358-1426 | KEEP signature; body shrinks slightly (no marker setup) but otherwise unchanged. |
| `WorkspaceManager.closeTab` insight branch | WorkspaceManager.swift L1109-1114 | KEEP — `session.cancel()` semantics unchanged. ADD: also delete the on-disk session cache directory `.insight-cache/<session.id.uuidString>/` before `tabsStore.removeTab`. |
| `WorkspaceManager.findInsightSession(sessionId:)` | WorkspaceManager.swift L1431-1438 | KEEP unchanged. |
| `WorkspaceManager.didRequestInsight*` 5 forwarders | WorkspaceManager.swift L1458-1515 | KEEP NAMES; `didRequestInsightSave` body changes (saves the rendered HTML or the per-node markdownBody equivalent). ADD: `didRequestInsightExportArchive` and `didRequestInsightIframeReady`. |
| `WorkspaceManager.scanMarkdownFiles(in:)` + `hasMarkdownFiles` | WorkspaceManager.swift L543-642 | KEEP unchanged. Already implements 500-file cap, symlink containment, `.skipsHiddenFiles`. |
| `GraphRAG.detectCommunities()` | GraphRAG.swift L28-103 | KEEP unchanged (pure clustering primitive). |
| `GraphRAG.escapeXMLEnvelopeBreakout` + `xmlAttrSafeCharacters` + per-file 50 KB / per-community 200 KB / 500-file caps | GraphRAG.swift L189-216, L554-589 | KEEP — same prompt-injection defense layer applies in v2. |
| `AIProviderClient.streamCompletion` | AIProviderClient.swift L208-322 | KEEP — both Phase 1 and Phase 2 use the same SSE method. Phase 1 may set `maxTokens: 2048`, Phase 2 per-section call sets ~3000-4000. |
| `AIProviderClient.sanitize`, `apiKeySnapshot`, error cases | AIProviderClient.swift L65, L421-424, L725 + `AIProviderError` cases | KEEP unchanged. |
| `AIProviderError + sanitize` redaction | InsightSession.swift L141, L699-702 | KEEP redaction semantics. |
| `ContentView` AI Tools menu button | ContentView.swift L130-131 | KEEP unchanged. |
| Tests/Fixtures/sse-anthropic-sample.txt | Tests fixtures | KEEP — SSE parser doesn't change. |

---

## 4. NEW tech needed (v2 introductions)

### 4.1 iframe srcdoc generation
Build pattern (host index.html JS, called from `window.loadInsightSkeleton`):
```js
function buildIframeSrcdoc(skeleton, libBlobUrls) {
  const css = "/* skeleton-loader pulse + node theme tokens */";
  const sectionDivs = skeleton.sections.map(s =>
    `<section id="sec_${s.id}" class="insight-section pending" data-type="${s.type}">
       <h2>${escapeHtml(s.title)}</h2>
       <div class="skeleton-loader"></div>
     </section>`
  ).join("");
  return `
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'self' blob: 'unsafe-inline'; connect-src 'none';">
      <style>${css}</style>
      <script src="${libBlobUrls.markdownIt}"></script>
      <script src="${libBlobUrls.mermaid}"></script>
      <script src="${libBlobUrls.katex}"></script>
      <script src="${libBlobUrls.chartJs}"></script>
      <script src="${libBlobUrls.prism}"></script>
    </head>
    <body>
      <main id="insight-root">${sectionDivs}</main>
      <script>
        window.__SKELETON__ = ${JSON.stringify(skeleton)};
        // Bootstrap: wait for sectionChunk messages from parent
        window.addEventListener('message', e => {
          // VALIDATE e.origin (parent's origin string) and e.data.type
          // Allowed inbound: 'sectionChunk' {sectionId, chunk}
          //                  'sectionDone' {sectionId}
          // ...append to corresponding #sec_<id>, run mermaid/katex post-render
        });
        window.parent.postMessage({type:'iframeReady', nodeId: window.__SKELETON__.nodeId}, '*');
      </script>
    </body>
    </html>
  `;
}
```
Then: `iframe.srcdoc = builtString`.

**Critical:** the `<script>` tags in srcdoc execute synchronously in a **null-origin** document. The injected libs work because they don't depend on origin. Mermaid's font loading may attempt to fetch external fonts; since CSP is `default-src 'self' blob:` + `connect-src 'none'`, network requests are blocked — verify mermaid still renders without external font (it does in default config).

### 4.2 postMessage parent ↔ iframe
**Inbound to parent (from iframe):** parent's `window.addEventListener('message', e => {...})` registered ONCE in host index.html. Validate:
1. `e.source === state.insightIframe.contentWindow` — message must come from our iframe (not from a window.opener etc).
2. `typeof e.data === 'object' && typeof e.data.type === 'string'`.
3. `e.data.type` ∈ allowlist `{iframeReady, deepDiveClicked, breadcrumbClicked, requestSave, requestUp}`.
4. Per-type payload validation (e.g. `deepDiveClicked.deepDiveIndex` is non-negative integer < skeleton.deepDives.length).
5. Forward to Swift via `sendToSwift('insightDeepDiveClicked', payload)` (the existing bridge.postMessage path).

**Outbound to iframe (from parent):** `state.insightIframe.contentWindow.postMessage({type, ...}, '*')`. Use `'*'` because the iframe origin is opaque-null (cannot specify a precise targetOrigin for null origins). This is acceptable because the iframe is OUR content (we built srcdoc) — there's no third-party listener.

**Risk:** if the user inspects the iframe via WebKit Web Inspector and crafts a postMessage from devtools console, parent will accept it. Mitigation: same validation as for any iframe message — payload validation must be strict (deepDiveIndex bounds-checked, sessionId matches current).

### 4.3 Disk cache (`<workspace>/.insight-cache/<session-uuid>/`)
**Layout:**
```
<workspace>/.insight-cache/
  <session-uuid>/
    manifest.json       (tree structure: nodes[].{id, parentId, title, level, scope})
    <node-uuid>.html    (one file per generated node, full standalone)
    <node-uuid>.skeleton.json  (Phase 1 JSON, kept for Export Archive / debugging)
```

**Swift APIs:** all `FileManager.default` — already used throughout (e.g. WorkspaceManager.swift L591-642 enumerator pattern). No new dependencies.

**Atomic writes (avoid corrupt cache on app crash):**
```swift
let temp = nodeFile.appendingPathExtension("tmp.\(UUID().uuidString)")
try html.write(to: temp, atomically: true, encoding: .utf8)
try FileManager.default.replaceItemAt(nodeFile, withItemAt: temp)
```
`replaceItemAt` is atomic on APFS.

**Eviction policy:**
- Per-session: `closeTab` for `.insight` kind already calls `session.cancel()` (WorkspaceManager.swift L1110-1114). Add: `try? FileManager.default.removeItem(at: cacheDir)` (best-effort).
- Crash recovery: on `startRecursiveInsight`, scan `.insight-cache/` for stale session dirs (compare against currently-open tabs' session UUIDs); orphans older than 24h get evicted.
- Global cap (per user-spec risk #4): 500 MB across all session dirs. LRU eviction at session level. Implement via `URLResourceKey.contentModificationDateKey`.

### 4.4 ZIP export via `Process` + `/usr/bin/zip`
**Reference pattern in codebase:** GitClient.swift L193-209 uses `Process()` with `/usr/bin/env`. Same shape:
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
process.currentDirectoryURL = stagingDir
process.arguments = ["-r", "-q", outputZipURL.path, "."]
let pipe = Pipe()
process.standardOutput = pipe
process.standardError = pipe
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
  let errBytes = pipe.fileHandleForReading.readDataToEndOfFile()
  throw InsightExportError.zipFailed(String(decoding: errBytes, as: UTF8.self))
}
```
**Sandbox:** `/usr/bin/zip` is a system binary; sandbox is OFF (entitlements L7-8) so `Process.run` works. (If sandbox were ever ON, this fails — flag as risk for future.)

**Staging directory layout (built before zip):**
```
<NSTemporaryDirectory>/insight-export-<uuid>/
  index.html               (renamed from root node's html)
  nodes/<node-uuid>.html
  manifest.json
  _assets/
    markdown-it.min.js
    mermaid.min.js
    katex.min.js
    katex.min.css
    chart.min.js
    prism.min.js
    prism-okaidia.min.css
    fonts/   (KaTeX fonts subdirectory — see vendor/css/fonts)
```
Each HTML file rewrites `<script src="blob:...">` → `<script src="../_assets/<libname>.js">` and similarly for CSS. Deep-dive button onclicks rewrite from `postMessage({type:'deepDiveClicked', ...})` → `window.location.href = '<node-uuid>.html'` (standalone navigation).

**NSSavePanel:** standard `let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.runModal()` — same pattern as `WorkspaceManager.saveInsightNode` (L1536-1567).

### 4.5 Pre-bundled libs distribution

**Currently in app bundle:** `MarkView/Resources/Editor/vendor/{js,css}/...` (see §2.3 inventory). Loaded by index.html `<script src="vendor/js/mermaid.min.js">` etc.

**At runtime for iframe:** parent index.html reads (via `fetch('vendor/js/mermaid.min.js').then(r=>r.text())` … or simpler: the libs are ALREADY loaded into the parent's window — just `.toString()` the loaded module if it's exposed). Cleanest:
```js
// At parent boot, once libs are loaded by their <script src="vendor/...">:
async function buildLibBlobs() {
  const libs = ['markdown-it.min.js','mermaid.min.js','katex.min.js','chart.min.js','prism.min.js'];
  const out = {};
  for (const name of libs) {
    const r = await fetch('vendor/js/' + name);
    const text = await r.text();
    out[name] = URL.createObjectURL(new Blob([text], {type: 'application/javascript'}));
  }
  return out;
}
```
Cache the result in `state.insightLibBlobs`. Reuse for every iframe srcdoc build.

**For ZIP Export:** Swift copies the actual files from `Bundle.main.url(forResource:..., subdirectory:"Editor/vendor/js")` to `<staging>/_assets/`. Path resolver pattern already exists at EditorView.swift L26-32.

**Chart.js does not exist in repo** — must be added. v1 didn't need it because v1 was markdown-only. Pin version: Chart.js 4.x (~250 KB minified). Place at `MarkView/Resources/Editor/vendor/js/chart.min.js`. Also requires updating Xcode project to copy the new resource (xcodegen auto-handles if `project.yml` has the right `sources` glob — check at impl time).

**Integrity:** v1 has no SRI hashes (CDN scripts at index.html L1197-1202 are plain `<script src="https://...">`). v2 should not regress; for the LOCAL libs there's no SRI need, but document the pinned versions in tech-spec so updates are deliberate.

---

## 5. Memory & performance

### 5.1 Single-iframe vs multi-iframe
**Decision (research-backed):** single iframe slot in the host page; on navigation (deep-dive click / breadcrumb), parent **resets** the iframe (`iframe.srcdoc = newContent` — implicit destroy of old document, new context bootstrap).
- Reset cost: ~50-100 ms (script re-parsing). Acceptable.
- Memory: only ONE active iframe context at a time. 50 cached node HTML files live ON DISK, not in memory.
- Alternative (keep prior iframe alive for instant back-navigation): 50 × ~10 MB iframe overhead = 500 MB resident. Rejected.

### 5.2 Per-node HTML size
- User-spec L82 cap: 2 MB per node. Enforce in `appendInsightSectionChunk` accumulator: when total bytes for a node > 2 MB → cancel stream, mark `.failed`, surface "node too large" error. Same eviction pattern as v1's per-node 10 MB rawBuffer cap (InsightSession.swift L580-589).
- 50 nodes × ~500 KB typical = 25 MB per session on disk. Within user-spec L78 budget.

### 5.3 Pre-bundled libs in iframe
- Strategy B (blob URLs from parent) — single in-memory copy of each lib in parent window. Each iframe `<script src="blob:...">` references it. WebKit dedupes script source by URL; multiple iframes don't multiply memory.
- Mermaid (2.8 MB) is the elephant. Consider: (a) lazy-load — only build mermaid blob URL if at least one section type is `mermaid`; (b) build an "extras" iframe for nodes that use mermaid, omit for nodes that don't. v2 should default to (a).

### 5.4 KaTeX font assets
- KaTeX uses webfonts in `vendor/css/fonts/`. CSS references them via relative URLs. From an iframe with srcdoc + blob CSS, those font URLs resolve to `about:srcdoc/...` and FAIL. Workaround: use KaTeX's `noFonts` rendering mode OR inline base64 the WOFF2 fonts into the CSS. Inline base64 is simpler — preprocess once at build time.

---

## 6. Concurrency

### 6.1 Phase 1 → Phase 2 sequencing
- Phase 1 must complete fully (JSON parsed) before Phase 2 sections can be addressed by ID. Parallel start is impossible.
- Strict JSON validation at end of Phase 1 stream: `JSONSerialization.jsonObject(with:)` + schema check (sections array of {id: string, title: string, type: enum, deepDives: array}). On failure → fallback to single-phase rendering: emit one "unstructured" section and stream all content into it.
- Latency: Phase 1 ~1-2 s (small response), Phase 2 sections begin immediately after.

### 6.2 Two-phase as one streaming call vs two calls
**Option A (single call with marker):** prompt asks LLM to emit `<<SKELETON>>{json}<<END_SKELETON>>` then per-section `<<SECTION:id>>html<<END_SECTION>>` blocks. Pros: 1 round-trip, 1 token bill. Cons: parser is brittle; section parallelism is fake (still one stream).

**Option B (two distinct calls):** Phase 1 = blocking call returns full JSON skeleton. Phase 2 = N parallel `streamCompletion` calls, one per section. Pros: true parallelism (N TCP streams in `withThrowingTaskGroup`); each section prompt can include skeleton context for coherence; failure of one section doesn't block others. Cons: N × prompt-token overhead; N × 300 ms TCP setup.

**Recommended (research finding, decision for tech-spec):** Option B. User-spec L31 explicitly wants parallel section fill. The token overhead is an acceptable tradeoff for the UX improvement. Use `mapReduceForFolder`'s existing `withThrowingTaskGroup` pattern (GraphRAG.swift L474-500) as the template — already proven, includes concurrency cap (`mapReduceMaxConcurrent = 5`).

### 6.3 LLM JSON compliance risk
- Anthropic Sonnet 4.6 generally follows strict JSON instructions but can wrap in markdown fences (```json) or include trailing prose. v2 must be tolerant:
  - Strip leading/trailing markdown fence markers before parsing.
  - Locate the first `{` and last matching `}` greedily.
  - On parse failure → fallback to single-phase (one section, full content streamed in). Mark `lastError = "skeleton parse failed; falling back"` (warning, not blocking).
- For maximum reliability consider Anthropic **tool use** with a strict JSON schema for Phase 1 instead of free-text JSON. Tool-use constrains output to schema. Slight latency increase but high reliability gain.

---

## 7. Risks (prominent)

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| **R1** | **WKWebView sandbox iframe gotchas** — `window.webkit.messageHandlers.bridge` may be auto-injected into nested frames. If iframe JS can call it directly, sandbox is moot. | **Critical** | Use `addScriptMessageHandler(_:contentWorld:name:)` with `forMainFrameOnly` semantics (verify at smoke test); validate `frameInfo.isMainFrame` Swift-side; rely on sandbox=allow-scripts (NO allow-same-origin) so the iframe is null-origin → `window.parent.webkit` is cross-origin-blocked from iframe's perspective. Smoke-test on Darwin 25.4 BEFORE locking the design. |
| **R2** | **Pre-bundled libs distribution + version pinning + integrity** — Chart.js missing; Mermaid 2.8 MB; KaTeX webfonts won't resolve from blob iframe. | High | Pin versions in tech-spec. Add Chart.js 4.x to `vendor/js/`. Inline-base64 the KaTeX woff2 fonts at build time. Lazy-load mermaid blob (only when needed). |
| **R3** | **ZIP export filesystem permissions / sandbox-OFF assumption** — relies on `Process` + `/usr/bin/zip`. If sandbox is ever re-enabled, breaks. | Medium | Document the dependency in tech-spec + add a precondition log. Same risk shape as `Process` already runs claude-cli today (AIConsoleEngine.swift) — already a known constraint. |
| **R4** | **Disk cache cleanup if app crashes mid-session** — `.insight-cache/<uuid>/` orphans accumulate. | Medium | On `startRecursiveInsight`: scan `.insight-cache/`, evict any session dir whose UUID doesn't match an open tab AND mtime > 24h. Global LRU eviction at 500 MB cap. |
| **R5** | **LLM JSON compliance for Phase 1 skeleton** — model may wrap in markdown fence, include trailing prose, or omit required fields. | High | Strict tolerant parser (strip fences, locate first/last brace), schema validation, explicit one-phase fallback. Strongly consider Anthropic tool-use with JSON schema for Phase 1. |
| **R6** | **Two-phase prompt single-call vs two-call** — single call cheaper but blocks true parallel section fill; two calls = parallelism + cost. | Medium | Research recommends two calls (Option B per §6.2). User-spec L31 explicitly wants parallel section fill. Confirm in tech-spec. |
| **R7** | **postMessage allowlist gaps** — any unvalidated payload field becomes a phishing/exfil vector if a malicious .md file influences LLM output. | High | Strict allowlist of 5 type strings (already in user-spec L55). Per-type schema validation: `deepDiveIndex` is non-negative int < skeleton-declared count; `nodeId` is a UUID string matching one in `session.nodes`; reject anything else with `console.warn` and don't forward to Swift. |
| **R8** | **iframe srcdoc stuck (LLM-generated infinite loop or alert spam)** | Medium | Set a `iframeReady` timeout: if iframe doesn't post `iframeReady` within 10 s, treat as broken — surface error, allow user to skip the node. `alert()` in null-origin sandboxed iframe is suppressed by WebKit by default; verify. |
| **R9** | **Memory: 50 iframe contexts** — would explode RAM. | Medium | Single iframe slot, srcdoc reset on navigate. Cached HTML lives on DISK. |
| **R10** | **Mermaid font fetch via CDN / external network** — even with CSP `connect-src 'none'`, mermaid may try a fetch and silently fail / log noise. | Low | Confirm mermaid default theme renders without external fetch (it does). Set mermaid `securityLevel: 'strict'` per-render (inherited from v1 Decision 7). |
| **R11** | **Tab close while streaming** — same as v1 R: cancellation must be synchronous before tab removal. | Low | Existing `closeTab` insight branch (WorkspaceManager.swift L1110-1114) already calls `session.cancel()` before `removeTab`. Extend to also invoke `try? FileManager.default.removeItem(at: cacheDir)`. |
| **R12** | **Chart.js + Mermaid + KaTeX + Prism size in standalone export** — `_assets/` will be ~3 MB. ZIP archive size may surprise users. | Low | Document in user-spec. Compress with `zip -9` for slight savings (mermaid is mostly already minified, marginal gain). |

---

## 8. Concrete file-level work plan derived from research

**Modified:**
- `MarkView/Models/InsightSession.swift` — full rewrite. Keep class signature, public method names, retry throttle, scope_hint validation, prompt-injection escape utilities, memory cap concept. Replace markdown-pipeline guts with skeleton+sections+per-node HTML pipeline plus disk cache I/O.
- `MarkView/Models/GraphRAG.swift` — KEEP `mapReduceForFolder`. Extract `reduceSystemPrompt` into a parameter so InsightSession can pass either Phase 1 (JSON-skeleton) or Phase 2 (per-section HTML) prompt; OR add a sibling `mapReduceSkeletonForFolder` method. Recommended: keep one method, parameterize the reduce prompt.
- `MarkView/Models/WorkspaceManager.swift` — `closeTab` insight branch adds disk-cache cleanup. `didRequestInsightSave` rewrites to save full HTML (or single-page export). NEW: `didRequestInsightExportArchive` (NSSavePanel + ZIP staging + `/usr/bin/zip`). NEW: `didRequestInsightIframeReady` (timing/timeout signal; minimal — just NSLog).
- `MarkView/Bridge/WebViewBridge.swift` — replace 5 insight commands with new set (per §2.4 table). Replace 5 insight message dispatch cases with new set. Add 2 new delegate protocol methods.
- `MarkView/Views/EditorView.swift` — `routeInsight` rewires to new Combine subjects (per-section chunks, breadcrumbs, status). Same teardown semantics.
- `MarkView/Resources/Editor/index.html` — DELETE the entire insight-mode JS block L2783-3225 and the right-pane DOM/CSS (L851-1018, L1113-1132). REPLACE with iframe-host JS (~600 lines): `state.insightIframe`, blob-lib bootstrap, `loadInsightSkeleton/appendInsightSectionChunk/finalizeInsightSection/loadCachedInsightNode/setInsightStatus/setInsightBreadcrumbs` window functions, `addEventListener('message', ...)` parent-side allowlist with strict per-type validation, breadcrumbs bar, status bar, iframe DOM.

**New files:**
- `MarkView/Models/InsightCache.swift` — disk cache CRUD (read/write per-node HTML, manifest.json, atomic writes, session dir lifecycle, global LRU eviction at 500 MB).
- `MarkView/Models/InsightExporter.swift` — ZIP staging + `Process(/usr/bin/zip)` driver + lib copy from `Bundle.main` to `_assets/` + HTML rewriter (blob: → ../_assets/...).
- `MarkView/Resources/Editor/vendor/js/chart.min.js` — pinned Chart.js 4.x.

**Untouched:**
- `MarkView/Models/AIProviderClient.swift`
- `MarkView/Models/DocumentState.swift` (TabKind stays)
- `MarkView/Models/CacheManager.swift`
- `MarkView/Models/SemanticDatabase.swift`
- `MarkView/Models/AIOrchestrator.swift`
- `MarkView/Views/ContentView.swift` (menu button stays)
- `MarkView/MarkView.entitlements` (sandbox-OFF stays)
- `MarkView/Resources/Editor/vendor/{js,css}/*.{js,css}` except adding chart.min.js

---

## 9. Open decisions for tech-spec

1. **Phase 2 strategy:** single call with section markers vs N parallel calls. Research recommends N parallel (true parallelism per user-spec L31; uses existing `withThrowingTaskGroup` pattern from `mapReduceForFolder`).
2. **Phase 1 enforcement:** free-text JSON with tolerant parser vs Anthropic tool-use with schema. Research recommends tool-use for reliability (~0% schema violation vs ~5-10% free-text).
3. **Mermaid lazy-load:** decide whether to always include mermaid blob in srcdoc (~2.8 MB per iframe context) or only when at least one section uses it. Lean toward lazy.
4. **KaTeX fonts:** inline base64 woff2 vs accept fallback rendering. Lean toward inline (one-time build cost; clean iframe behavior).
5. **Disk cache TTL on close:** user-spec L40/L93 says erase on tab close, optionally keep via Settings (TBD). For v2 first cut: always erase. Add Settings toggle later.
6. **ZIP standalone navigation:** how do `🤿 Deep dive` buttons work in the exported HTML? They can't `postMessage` to a parent — there is no parent. Solution: in the exporter, rewrite each button's onclick to `window.location.href = '<deepDiveTarget>.html'` (file-relative navigation). Standalone HTML navigates between files like a static site. Same for breadcrumbs.
