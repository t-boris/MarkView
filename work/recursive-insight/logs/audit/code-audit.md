# Code Audit — Recursive Insight v2

**Date:** 2026-04-30
**Auditor:** code-reviewing skill (Task 9)
**Scope:** Tasks 1-8 outputs (12 files, ~12.1k LOC)
**Verdict:** PASS-WITH-FOLLOWUPS

## Executive Summary

The v2 implementation is structurally sound and the most safety-critical lessons from the v1 audit (especially `[weak self]` discipline and the 5-type postMessage allowlist) have been applied with discipline across every long-lived closure and bridge handler. **Three concrete bugs** prevent unconditional PASS: (1) `InsightSession.buildHTMLTemplate` references vendored libs by hard-coded names that disagree with the actual filenames copied into `_assets/` (`chart.umd.min.js`, `prism.min.css`) — every cache-rebuilt page and every ZIP export will 404 those scripts; (2) the cache-side CSP at `InsightSession.swift:1070` (`default-src 'self' 'unsafe-inline' blob: data:`) is far weaker than the iframe-srcdoc CSP and far weaker than the standalone-export expectation; (3) `InsightCache.copyVendoredLibs` skips subdirectories so KaTeX webfonts are missing from `_assets/`, breaking math rendering in any export. The `[weak self]` audit found zero violations across 8 long-lived Task / Combine / SSE-callback closures inspected. Hand-traces (j) and (k) both succeed structurally. Eleven additional findings (4 major, 7 minor) listed below.

## Findings Summary

| Severity | Count |
|----------|-------|
| blocker  | 0     |
| major    | 4     |
| minor    | 7     |
| nit      | 3     |

> **Note on severity:** The three filename / CSP / webfont issues are graded `major` rather than `blocker` because (a) they affect CACHE-WRITE + ZIP-EXPORT paths (Decisions 4 + 7), not the live runtime path which uses fresh blob URLs from `index.html`; the runtime UI works, but every cache hit and every exported archive ships broken scripts. (b) The audit verdict gates the Final Wave but the issues are localized to one Swift file plus the InsightCache copy loop and can be patched in <30 lines. They MUST be fixed before T11 functional testing or QA will report them as test failures.

## Findings by Dimension

### a. `[weak self]` discipline (CRITICAL)

Every long-lived closure inspected (8 sites). Coverage is the deliverable here, not just failures.

| # | File | Line(s) | Closure context | Capture | Verdict |
|---|------|---------|-----------------|---------|---------|
| 1 | InsightSession.swift | 372-385 | `activeTask = Task { … }` inside `generateRoot()` | `[weak self]` + `guard let self else { return }` | OK |
| 2 | InsightSession.swift | 457-469 | `activeTask = Task { … }` inside `expand(sectionId:topicIndex:)` | `[weak self]` + guard | OK |
| 3 | InsightSession.swift | 553-567 | `activeTask = Task { … }` inside `retryCurrent()` | `[weak self]` + guard | OK |
| 4 | InsightSession.swift | 758-801 | `withThrowingTaskGroup { … group.addTask { [weak self] … } … }` Phase-2 fan-out | Outer body: no closure capture (TaskGroup body runs synchronously inside the awaited group); each `group.addTask { [weak self] in }` captures weak; nested `onDelta` captures `[weak self]`; nested `Task { @MainActor [weak self] in }` captures weak. Triple-weak chain verified. | OK |
| 5 | InsightSession.swift | 782-791 | `onDelta:` closure passed to `streamCompletion` (off-actor SSE byte pump) | `[weak self]` (outer) + nested `Task { @MainActor [weak self] in guard let self else { return } }` | OK |
| 6 | EditorView.swift | 309-312 | `workspaceManager.releaseInsightBlobsHook = { [weak self] in … }` | `[weak self]` + `guard let self = self, let webView = self.webView else { return }` | OK |
| 7 | EditorView.swift | 322-334, 349-372, 382-391, 402-412 | Four Combine `.sink` closures (`$skeleton`, `$currentNodeSections`, `$lastError`, `$statusMessage`) | All four declare `[weak self, weak session, weak webView]` and unwrap all three | OK |
| 8 | WorkspaceManager.swift | 1133-1156 | `Task { @MainActor in … }` inside `closeTab` insight branch | **No `[weak self]` capture; uses `self.openTabs[…]` and `self.tabsStore.removeTab` directly via implicit strong capture.** WorkspaceManager is the singleton root of the dependency graph (`@StateObject` lifetime), so the strong reference is intentional and not a leak vector. Documented inline. | OK (intentional) |
| 9 | InsightArchiveExporter.swift | 165-170 | `process.terminationHandler = { _ in continuation.resume() }` | No self at all (static helper, pure-fn closure). | OK |
| 10 | InsightSession.swift | 372, 457, 553 | `activeTask = Task { … }` (re-iterated for completeness) — all three sites cancel before reassign? | Yes — `expand()` cancels prior `activeTask` at L432 before assigning; `retryCurrent()` cancels at L550 before assigning; `generateRoot()` is gated by `activeTask != nil` idempotency check at L338. | OK |

**Findings:** none.

### b. Async error propagation

| # | Path | Severity | Description |
|---|------|----------|-------------|
| b1 | InsightSession.swift:380-382, 465-467, 563-565 | OK | All three Task entry points wrap pipeline in `do { … } catch { handleStreamError(error, forNodeId: nodeId) }` — errors land in the pattern table at L1108. |
| b2 | InsightSession.swift:618-708 | OK | `phase1Skeleton` rethrows network/API errors and validates section uniqueness. |
| b3 | InsightSession.swift:758-810 | OK | `phase2StreamSections` uses `withThrowingTaskGroup` — Swift runtime cancels siblings on first throw. **Acknowledged deviation from spec:** the spec text in Risks ("Phase 2 N parallel calls hit Anthropic rate limit → mark only that section .failed and do not cancel the whole group") is NOT fulfilled by the current implementation: any per-section `streamCompletion` throw aborts the group. See finding `b-major-1` below. |
| b4 | InsightCache.swift:111-127, 147-165 | OK | `writeNode` and `updateManifest` propagate errors; orphan `.tmp` removed in `catch`. |
| b5 | InsightArchiveExporter.swift:129-140 | OK | Non-zero exit translates to `InsightArchiveExporterError.zipFailed(sanitizedStderr)`. |
| b6 | AIProviderClient.swift:712-735 | OK | `toolCall` sanitizes HTTP body before throwing (Decision 8). |

**b-major-1 (major, InsightSession.swift:758-801):** `withThrowingTaskGroup` semantics cancel siblings on first throw. Tech-spec Risks row "Phase 2 N parallel calls hit Anthropic rate limit" requires per-section isolation: a single 429 should mark only that section `.failed`, leaving the other 4 to complete. **Suggested fix:** wrap the body of each `group.addTask` in `do { try await … markSectionReady } catch { await self.markSectionFailed(sectionId: …) }` so the group never sees a throw and does not cancel siblings. This requires adding `markSectionFailed` (mirror of `markSectionReady`) and not using `try await` at the group level — instead `for await _ in group { }` so failures don't propagate.

### c. Task cancellation

| # | Path | Verdict |
|---|------|---------|
| c1 | InsightSession.cancel() L508-515 | OK — awaits `activeTask.value`; `Task<Void, Never>.value` cannot throw. |
| c2 | Phase 2 group children observe `Task.isCancelled` between SSE lines via `streamCompletion`'s per-line check (L189-192 of AIProviderClient.swift). On cancel they unwind within ~1s. | OK |
| c3 | InsightArchiveExporter.bundle L98-112 | OK — `withTaskCancellationHandler { … } onCancel: { process.terminate() }` sends SIGTERM; the post-exit branch detects `Task.isCancelled` BEFORE inspecting `terminationStatus` and surfaces `.cancelled` rather than `.zipFailed(143)`. `.tmp` removed in cancellation path. |
| c4 | WorkspaceManager.closeTab insight branch L1130-1156 | OK — STRICT 4-step order: `releaseHook?()` → `await session.cancel()` → `try? session.cache.cleanup()` → re-resolve index → `tabsStore.removeTab`. The re-resolve (L1150-1154) protects against `index` going stale during the await. |
| c5 | WorkspaceManager.exportInsightArchive L1697-1727 | OK — `Task { @MainActor in … }` wraps the export; `defer { try? fm.removeItem(at: exportRoot) }` runs on success/failure/cancellation. |

**Findings:** none.

### d. Swift conventions

| # | File | Line | Severity | Issue / Note |
|---|------|------|----------|-------------|
| d1 | InsightSession.swift:178 | — | OK | `@MainActor final class InsightSession: ObservableObject, Identifiable` — correct |
| d2 | InsightSession.swift:202-247 | — | OK | All 10 `@Published` are `private(set)` |
| d3 | InsightSession.swift:260, 264 | — | minor | v1-compat shims `streamingBuffer`, `isStreaming` are `@Published` empty placeholders. Documented as removable by T7; T7 has now landed. **d-minor-1** |
| d4 | InsightModels.swift:11-17 | — | OK | `InsightSkeleton: Codable`. No Sendable annotation but the struct is value-type with all-Codable fields, so implicit Sendable applies. |
| d5 | InsightSession.swift:103-152 | — | OK | `InsightNode: final class, Identifiable, Codable` — reference type by design (mutated in place by section streaming). |
| d6 | InsightSession.swift:286-300 | — | OK | `init` body assigns all stored properties; clear and minimal. |
| d7 | InsightSession.swift:310-330 | — | minor | The "v1-compat throwing convenience init" creates a SECOND InsightCache rooted under temp dir. After T8 lands, no caller exercises this init (WorkspaceManager.startRecursiveInsight uses the 5-arg init at L1463). **d-minor-2** |
| d8 | InsightModels.swift:37 | — | OK | `metadata: [String: AnyCodable]` (non-optional) — sample fixture provides `metadata` for every section so JSON decode succeeds. |
| d9 | WorkspaceManager.swift various `case .insight` branches | — | OK | 11 grep hits, all defensive guards (saveActiveFile, saveFile(at:), reloadActiveTabFromDisk, openOrRefreshFile, updateActiveTabContent, reindexActiveFile, handleBlocksDelta, findInsightSession, activeInsightSession, closeTab, firstIndex re-resolve). |

**Findings:**

- **d-minor-1 (minor, InsightSession.swift:259-264):** v1-compat shims `streamingBuffer`, `isStreaming` are now dead weight after T7. EditorView.swift no longer subscribes to them (verified by grep). **Suggested fix:** delete both `@Published` declarations + their MARK comment block.
- **d-minor-2 (minor, InsightSession.swift:310-330):** v1-compat throwing convenience init no longer has callers (verified: WorkspaceManager.startRecursiveInsight uses the 5-arg init at L1463). **Suggested fix:** delete the convenience init.

### e. Shared-resources compliance

| Resource | Pattern | Verdict |
|----------|---------|---------|
| `AIProviderClient` | One per WorkspaceManager (created inside `incrementalCompiler.orchestrator`); passed to InsightSession at L1466 and used by GraphRAG's stored `providerClient` ref | OK |
| `GraphRAG` | Singleton injected via `WorkspaceManager` (`graphRAG` property); passed to InsightSession at L1467 | OK |
| `InsightCache` | Created exactly once in `WorkspaceManager.startRecursiveInsight` L1454 and passed in. Held as `let` on InsightSession L191. No second instance constructed mid-flight. The v1-compat init at L310-330 creates an extra cache but has no live callers (see d-minor-2). | OK |
| `Process /usr/bin/zip` | Spawned exclusively inside `InsightArchiveExporter.bundle` L76-99. No other call sites. | OK |
| Vendored libs blob URLs | `index.html` lazy materialization via `ensureLibBlob` (L2753); cached in `state.insightBlobURLs`; revoked on session change AND on `releaseInsightBlobs`. One blob URL per lib per session. | OK |

**Findings:** none.

### f. JS code quality (insight-mode block in index.html)

Coverage: lines 2664-3432.

| # | File:Line | Severity | Description |
|---|-----------|----------|-------------|
| f1 | index.html:2877 | OK | `'use strict'` declared inside iframe-side script body. |
| f2 | global parent-side block | minor | No `'use strict'` declaration at the top of the parent insight block — function-level only. The parent JS is wrapped in an IIFE inherited from earlier code. **f-minor-1** |
| f3 | index.html:2714, 2724, 3323, 3330 | OK | All declarations use `const`; no `var` in v2 block. (The IIFE inside iframe srcdoc uses `var` because it targets a minimal sandboxed runtime — acceptable.) |
| f4 | index.html:3309-3316 | OK | `releaseInsightBlobs` revokes ALL blob URLs and clears caches. |
| f5 | index.html:3068-3094 | OK | Breadcrumbs render via `textContent` only (parent chrome). NO `innerHTML` on parent side for LLM strings. |
| f6 | index.html:3100-3107 | OK | Status bar `bar.textContent = …` — parent chrome uses textContent. |
| f7 | index.html:2828, 2851, 2857, 2885 | OK | Iframe srcdoc construction interpolates LLM strings via `escapeForHTMLText` / `escapeForHTMLAttribute` (Decision 10). |
| f8 | index.html:2885 | minor | The iframe-side `escAttr` function is defined inside the srcdoc string — it duplicates `escapeForHTMLAttribute`. Iframe-side use is **inside the trust boundary** (sandbox null-origin) so this is permissible per the audit dimension's "iframe-side innerHTML/outerHTML/etc are ALLOWED". The duplication is a minor maintainability issue. **f-minor-2** |
| f9 | index.html:2943 | OK | Iframe-side `ph.insertAdjacentHTML('beforeend', String(p.htmlChunk||''))` — LLM-trusted within iframe sandbox, per Decision 2. |
| f10 | index.html:3148-3163 | OK | `stripCDNTags` regex correctly strips `<script src="https?:|//…">` and `<link rel="prefetch|preconnect|dns-prefetch">` BEFORE forwarding to iframe. Defense-in-depth on top of CSP `connect-src 'none'`. |
| f11 | index.html:3289-3293 | minor | `setInsightError` mutates `bar.textContent` twice on retryable path — once in `setStatusBar(message,…,true)` and once again with appended hint. Single write would be cleaner; current behaviour is correct because the second textContent assignment is unconditionally overwriting. **f-minor-3** |

**Findings:**
- **f-minor-1:** Add `'use strict';` at the top of the parent insight IIFE for explicit hardening.
- **f-minor-2:** Both iframe-side `escAttr` and parent-side `escapeForHTMLAttribute/Text` are duplicates. Maintain in one place (parent) and inject the iframe-side variant via the iframe srcdoc template literal. Acceptable as-is; cleanup task.
- **f-minor-3:** Collapse the double `bar.textContent` assignment into one. Cosmetic.

### g. postMessage allowlist correctness

| Check | Verdict |
|-------|---------|
| Exactly 5 JS→Swift types | OK — `INSIGHT_ALLOWED_TYPES` set at index.html:3323-3329 lists all 5 (`insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`); Swift switch at WebViewBridge.swift:113-136 has the same 5 cases. No 6th type. |
| `event.source === iframe.contentWindow` AND `event.origin === 'null'` | OK — index.html:3338-3345. |
| Per-type payload schema validation | OK — every case has explicit type/range checks (index.html:3382-3416). |
| Malformed payload rejection with sanitized log | OK — `console.warn` on JS side; `Self.sanitizeForLog(…)` at WebViewBridge.swift:165, 179, 193. |
| `insightDeepDiveClicked` bounds-checks `topicIndex` against `skeleton.sections[sectionId].deepDiveTopics` | OK at index.html:3395-3398 (parent JS), again at WorkspaceManager.swift:1553-1561 (Swift defense-in-depth). |
| `insightBreadcrumbClicked` validates UUID regex AND manifest membership | OK — UUID regex at index.html:3409, manifest check at WorkspaceManager.swift:1583-1587. |

**Findings:** none.

### h. frameInfo defense-in-depth (Decision 3)

EVERY v2 case in `userContentController` opens with `guard message.frameInfo.isMainFrame else { return }`:

- WebViewBridge.swift:115 — insightIframeReady ✓
- WebViewBridge.swift:119 — insightDeepDiveClicked ✓
- WebViewBridge.swift:123 — insightBreadcrumbClicked ✓
- WebViewBridge.swift:127 — insightRequestSave ✓
- WebViewBridge.swift:131 — insightRequestUp ✓

Count: 5/5. No v1 insight cases remain in the file (verified by grep). `headingsUpdated` and `blocksChanged` are non-insight legacy handlers and are dispatched ABOVE the insight switch (lines 84-105) — they are not subject to the v2 `frameInfo` requirement.

**Findings:** none.

### i. Iframe sandbox correctness (Decision 2)

| Check | Verdict |
|-------|---------|
| Static `<iframe>` element has `sandbox="allow-scripts"` | OK — index.html:1013. |
| JS setter re-applies `sandbox="allow-scripts"` (defense-in-depth on srcdoc reload) | OK — index.html:3237. |
| No `allow-same-origin`, `allow-popups`, `allow-forms`, `allow-modals`, `allow-top-navigation` | OK — grep shows zero hits in index.html. |
| Iframe srcdoc CSP matches Acceptance Criteria spec | OK — index.html:2827 emits `default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'` — byte-identical match. |

**Finding:**
- **i-major-1 (major, InsightSession.swift:1070):** The CSP baked into `writeFinalHTMLToCache` (cache-stored HTML used by navigateTo cache hits AND by ZIP export) is `default-src 'self' 'unsafe-inline' blob: data:; img-src * data: blob:; font-src * data:;` — this is dramatically more permissive than the spec-mandated iframe CSP. Cached HTML pages opened via the standalone-export ZIP run with this weak CSP, allowing `img-src *` (any CDN), `font-src *`, and `default-src 'self'` (which means the script tags injected via `../_assets/...` succeed only on `file://` schemes that happen to resolve `'self'` to the ZIP root — fragile). **Suggested fix:** Replace the CSP at L1070 with the same `default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; …` pattern from the iframe srcdoc, but with `'self'` instead of `blob:` because the export uses relative `_assets/` references. Specifically: `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`.

### j. Hand-trace: tool_use sample → InsightSkeleton parse

**Input:** `Tests/Fixtures/insight-skeleton-sample.json` (83 lines, structurally faithful to the Anthropic Messages API `tool_use` envelope).

**Step 1 — `AIProviderClient.toolCall` ingestion (HTTP path).** The fixture is the synthetic response body — no actual HTTP call. We hand-trace the response-parsing branch starting at AIProviderClient.swift:712:
- L712: `(responseData, response) = try await session.data(for: request)` — would receive the fixture bytes.
- L713-718: HTTP 200 (the fixture has no status; assume 200). No throw.
- L720-723: `JSONSerialization.jsonObject(with: responseData) as? [String: Any]` — fixture's top-level dict (`id`, `type`, `role`, `model`, `stop_reason`, `stop_sequence`, `content`, `usage`) decodes successfully.
- L727-733: Iterate `contentBlocks`. The fixture has ONE block at index 0, type `tool_use`. `block["input"] as? [String: Any]` returns the `input` dict containing `title`, `suggestedTheme`, `sections`. `return input`.

**Step 2 — `GraphRAG.buildSkeleton` parse (line 798-815).**
- L800: `JSONSerialization.data(withJSONObject: dict, options: [])` — re-serialises the dict to JSON bytes. Round-trip safe.
- L801: `JSONDecoder().decode(InsightSkeleton.self, from: data)` — must decode 4 sections (`hero-overview`, `architecture-diagram`, `design-decisions`, `feature-comparison`).
  - `title: "Project Architecture Overview"` → `InsightSkeleton.title` ✓
  - `suggestedTheme: "dark"` → optional String ✓
  - For each section: `id` (String), `type` (`"hero"` / `"mermaidDiagram"` / `"prose"` / `"comparisonTable"` — all in `SectionType` enum) ✓, `title` (optional String) ✓, `scopeHint` ([String]) ✓, `metadata` ([String: AnyCodable]) — fixture metadata uses `String`, `Int`, and array values, all of which are decodable into `AnyCodable` cases ✓, `deepDiveTopics` (optional, `null` for sections 1/2/4, populated for section 3) ✓.
  - `design-decisions.deepDiveTopics[0]` = `{id: "dd-iframe-sandbox", label: "…", hint: "…", scopeHint: [...]}` — all four required fields present per `InsightDeepDiveTopic` schema ✓.

**Step 3 — `InsightSession.phase1Skeleton` storage (L618-708).**
- L649-681: section id uniqueness check passes (all 4 ids are unique).
- L660-664: `validateScopeHint` runs against the file paths — in a real folder these resolve to URLs; the fixture paths (`README.md`, `docs/overview.md`, `MarkView/Views/EditorView.swift` etc.) would fail the `.md` extension check for the `.swift` ones, producing NSLog warnings but not throwing.
- L670-678: deep-dive topic id uniqueness — both topic ids unique within section.
- L683-705: published `skeleton`, `skeletonReady = true`, initialised `currentNodeSections` with 4 empty `SectionState()` entries.

**Verdict:** Happy path decodes cleanly. Fallback path (Self.fallbackSkeleton) is exercised only on schema violation; sample is schema-conforming.

**Edge-case note:** the fixture's section 3 `scopeHint` includes `"docs/decisions/"` (a directory, not a file) and section 2/3 mix `.md` and `.swift` paths. Real LLM output is unlikely to do this; the validation (`pathExtension.lowercased() == "md"`) at InsightSession.swift:1243 will drop `.swift` paths cleanly with NSLog warnings, and the directory path resolves to a directory URL whose `pathExtension` is empty so it too will be dropped.

**Findings:** none structural.

### k. Hand-trace: ZIP staging dir construction

**Scenario:** 3-node session — root + 2 children expanded from root section `design-decisions` topic indexes 0 and 1.

**Step 1 — InsightCache root layout** (after construction at WorkspaceManager.swift:1454):
```
<folderURL>/.insight-cache/<sessionUUID>/
├── _assets/                  (vendored libs copied flat per copyVendoredLibs)
│   ├── chart-4.4.9.min.js    (FLAT NAME PER VENDOR — see k-major-1 below)
│   ├── prism.min.js
│   ├── mermaid.min.js
│   ├── katex.min.js
│   ├── auto-render.min.js
│   ├── prism-okaidia.min.css (FLAT NAME)
│   ├── katex.min.css
│   ├── prism-line-numbers.css
│   ├── prism-diff-highlight.css
│   ├── markdown-it.min.js, prism-*.js (16+ language plugins), markdown-it-*.min.js, js-yaml.min.js
│   └── (NO fonts/ subdirectory — copyVendoredLibs SKIPS subdirectories at L272-274)
├── nodes/
│   ├── <rootUUID>.html      (root node HTML, written by writeFinalHTMLToCache with `..//_assets/` lib refs)
│   ├── <child1UUID>.html
│   └── <child2UUID>.html
└── manifest.json             (load-or-init shape from updateManifest)
```

**Step 2 — `archiveStagingDirectory()`** returns `rootDirectory` unmodified (per Decision 4). InsightCache does NO HTML rewriting.

**Step 3 — `WorkspaceManager.exportInsightArchive`** (L1697-1727):
- L1704: `makeExportStagingCopy(from: stagingURL)` creates `NSTemporaryDirectory()/insight-export-<uuid>/` and copies `_assets/`, `nodes/`, `manifest.json` into it. Live cache untouched.
- L1708-1712: `rewriteForStandaloneExport(exportRoot:rootNodeId:nodeChildMap:)`:
  1. Promote root: `nodes/<rootUUID>.html` → `index.html` at staging root. Rewrite `"../_assets/` → `"_assets/`. Rewrite deep-dive `<button>` → `<a href="nodes/<childUUID>.html">`. Rewrite breadcrumbs (root has none, but the regex sweep is safe).
  2. For each `nodes/<uuid>.html`: rewrite deep-dive buttons to `<a href="<childUUID>.html">` (sibling). Rewrite breadcrumb hrefs: `<a href="#<uuid>">` → root crumb gets `../index.html`, sibling crumbs get `<uuid>.html`.
- L1714-1715: `InsightArchiveExporter.bundle(stagingURL: exportRoot, to: destinationURL)`:
  - `cd <exportRoot> && /usr/bin/zip -r <dest>.zip.tmp .`
  - On success, atomic `replaceItemAt` swaps `.tmp` → `.zip`.

**Step 4 — Final ZIP structure:**
```
<destination>.zip
├── index.html                (formerly nodes/<rootUUID>.html, lib refs `_assets/...`)
├── nodes/
│   ├── <rootUUID>.html       (still in nodes/, used as the file the root crumb references via "../index.html" — but actually targeted via "../index.html" so this file is unreachable from non-root pages; harmless dead file)
│   ├── <child1UUID>.html
│   └── <child2UUID>.html
├── _assets/
│   └── (libs as listed above; webfonts MISSING — see k-major-2)
└── manifest.json
```

**Findings:**

- **k-major-1 (major, InsightSession.swift:1051-1058 — ALSO surfaces in the cache HTML BEFORE export):** The hard-coded `exportLibs` list references files that disagree with what InsightCache actually copies into `_assets/`:
  - `("chart.umd.min.js", "js")` — vendor file is `chart-4.4.9.min.js`. After ZIP export the page references `_assets/chart.umd.min.js` which does not exist. Charts will not render in the export OR in the cache-rebuilt HTML opened via `cachedNodeHTML` (cache-read path).
  - `("prism.min.css", "css")` — vendor css folder has `prism-okaidia.min.css`, `prism-line-numbers.css`, `prism-diff-highlight.css`. There is NO `prism.min.css`. Code highlighting will lack a stylesheet.
  
  Note: the live runtime path (skeleton → blob URL → iframe srcdoc) is fine because it uses `INSIGHT_LIB_FILES` in index.html which references the correct names. The bug is exclusive to `writeFinalHTMLToCache`'s `LibRefMode.exportRelative` branch.
  
  **Suggested fix:** read the actual `_assets/` directory contents at write time (or at session init) and emit `<script src="…">` for every `.js` and `<link>` for every `.css` discovered. Alternatively, fix the hard-coded list to match the actual vendor layout: `chart-4.4.9.min.js`, `prism.min.js`, `prism-okaidia.min.css`, `prism-line-numbers.css`, `katex.min.css`, `katex.min.js`, `auto-render.min.js`, `mermaid.min.js`. Better yet, share the source-of-truth list with `INSIGHT_LIB_FILES` in index.html (e.g. via a JSON manifest at `vendor/MANIFEST.json` consumed by both).

- **k-major-2 (major, InsightCache.swift:266-274):** `copyVendoredLibs` skips subdirectories with the comment "If a future change needs them, copy recursively here." The KaTeX webfonts live in `Resources/Editor/vendor/css/fonts/` and are referenced by `katex.min.css` via relative `url(fonts/KaTeX_*.woff2)` paths. Because `_assets/` is flat AND has no `fonts/` subdir, ANY math section in the exported ZIP will render with KaTeX fallback fonts (or fail to render entirely). The runtime path inlines fonts as base64 data URLs (index.html:2783-2818) — the export path does not.
  
  **Suggested fix:** either (a) extend `copyVendoredLibs` to recursively copy subdirectories so `_assets/fonts/` exists, AND have the export's CSS rewriting pass change `url(fonts/…)` → `url(fonts/…)` (already correct relatively) — paths just work; or (b) at HTML rewrite time inline the webfonts as base64 into a `<style>` block (mirrors index.html's runtime behaviour). Option (a) is simpler — 4 lines in copyVendoredLibs.

- **k-minor-1 (minor):** The ZIP archive contains a duplicate `nodes/<rootUUID>.html` left in place after promotion (used by the comment at L1837-1840 as the breadcrumb-up target — but the rewriting actually targets `../index.html`, so the duplicate is unreachable). Harmless extra file. **Suggested fix:** delete `nodes/<rootUUID>.html` after promotion to `index.html`.

### l. Vendored libs MANIFEST integrity

| Check | Result |
|-------|--------|
| `Resources/Editor/vendor/MANIFEST.txt` exists | YES |
| Header documents pipe-delimited shape | YES (lines 1-7) |
| Each row: `lib_name | version | sha256 | source_url | cve_check_date | cve_check_result` | YES — verified for `chart.js | 4.4.9 | bce15408…c844 | https://cdn.jsdelivr.net/npm/chart.js@4.4.9/dist/chart.umd.min.js | 2026-04-30 | clean` (line 28) |
| `chart-4.4.9.min.js` present in `vendor/js/` | YES (verified by `ls`) |
| Mermaid CVE attribution corrected (round-1 fix) | YES — line 29 explicitly notes the 2025-CVE corrections |
| KaTeX risk-accepted with rationale | YES — line 30 |
| All 50 vendored assets enumerated (per decisions.md T2 entry) | YES — 50 rows visible (1 chart, 1 mermaid, 2 katex js, 1 mdit, 3 mdit plugins, 1 js-yaml, 17 prism, 4 css, 20 katex webfonts) |

**l-nit-1 (nit, MANIFEST.txt:28):** the `source_url` column for chart.js points to `chart.umd.min.js` (the upstream filename) but the on-disk vendored file was renamed to `chart-4.4.9.min.js`. This is a documented choice (versioning embedded in filename) but creates the indirection trap that drives k-major-1. Add a `local_filename` column or a header note linking the two.

## Followups

These items should be appended to `tasks/todo.md` under heading **"From T9 code audit"** because the verdict is `PASS-WITH-FOLLOWUPS`:

1. **Fix exportRelative lib references (k-major-1).** Update `InsightSession.buildHTMLTemplate` `exportLibs` list at L1051-1058 to match actual `_assets/` filenames (`chart-4.4.9.min.js` not `chart.umd.min.js`; `prism-okaidia.min.css` not `prism.min.css`). Better: derive the list at runtime from `cache.assetsDirectory` contents.

2. **Copy KaTeX webfonts into `_assets/` (k-major-2).** Extend `InsightCache.copyVendoredLibs` to recursively copy subdirectories OR special-case `vendor/css/fonts/`. Without this, math rendering breaks in every standalone export.

3. **Tighten cache-stored CSP (i-major-1).** Replace the `default-src 'self' 'unsafe-inline' blob: data:; img-src * data: blob:; font-src * data:` CSP at InsightSession.swift:1070 with the strict CSP variant that uses `'self'` instead of `blob:` for the export context. Wildcard `img-src *` and `font-src *` are unnecessary for Markdown-only insight content.

4. **Per-section error isolation in Phase 2 (b-major-1).** Wrap each `group.addTask` body in a do/catch that calls `markSectionFailed(sectionId:forNodeId:)` instead of letting the error propagate to the group level. Implement `markSectionFailed` mirroring `markSectionReady`. Replace `try await group.waitForAll()` with `for await _ in group { }`. Aligns with tech-spec Risks row "Phase 2 N parallel calls hit Anthropic rate limit".

5. **Delete v1-compat shims (d-minor-1, d-minor-2).** Remove `InsightSession.streamingBuffer` and `isStreaming` published shims (L259-264) and the throwing convenience init (L310-330). T7 has fully replaced their callers.

6. **Delete dead code: `GraphRAG.mapReduceForFolder` (audit dimension 12).** Confirmed by full-source grep — no production caller remains. Definition spans GraphRAG.swift L233-538 (~305 lines). Removing it reduces code footprint and eliminates the maintenance trap of a parallel "v1 path" that may quietly drift.

7. **Optional cleanup: collapse `nodes/<rootUUID>.html` after promotion (k-minor-1).** Delete the duplicate after copying to `index.html`.

8. **Optional cleanup: `'use strict'` on parent insight IIFE (f-minor-1).** Single-line addition.

9. **Optional cleanup: extract `LogSanitizer` utility (per WebViewBridge.swift:148-149 inline TODO).** WebViewBridge and WorkspaceManager carry duplicate `sanitizeForLog` definitions; InsightArchiveExporter has yet another `sanitizeForError`. Folding into one utility tightens future maintenance.

10. **Optional: source-of-truth lib manifest (k-major-1 + l-nit-1 reflection).** A single `vendor/lib-manifest.json` consumed by index.html (`INSIGHT_LIB_FILES`), InsightSession (`exportLibs`), and the MANIFEST.txt generator would prevent any future drift between the three.

## Verdict justification

- Zero blocker findings. Zero `[weak self]` violations across 8 inspected closures.
- Four major findings (b-major-1, i-major-1, k-major-1, k-major-2) — each is local, has a concrete fix, and does not invalidate the architecture.
- Three of the four majors block correct ZIP export / cache-hit rendering; one (b-major-1) is a contract gap with a tech-spec risk row.
- Minor findings are dead-code cleanup and stylistic.
- Per the "Status Decision Matrix" in the code-reviewing skill: 4 major findings would normally trigger `changes_required`; however the audit task spec defines a coarser ladder (`PASS / PASS-WITH-FOLLOWUPS / FAIL`) and the failures are not ship-stoppers for the in-app live runtime, only for the export path. **PASS-WITH-FOLLOWUPS** is the correct verdict — the 4 major items must be tracked into `tasks/todo.md` under "From T9 code audit" and resolved before T11 functional QA exercises the export path.
