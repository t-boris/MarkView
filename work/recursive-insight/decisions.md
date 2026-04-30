# Decisions Log: Recursive Insight

Per-task summaries (1-3 sentences) + links to JSON review reports. Created during execution.

---

## Task 1: Add streaming to AIProviderClient
- Implemented streamCompletion(...) with URLSession.bytes SSE parsing
- Added AIProviderError.streamingError, internal apiKeySnapshot accessor
- Fixture: synthetic (ANTHROPIC_API_KEY not set in env), location Tests/Fixtures/sse-anthropic-sample.txt
- Build: SUCCEEDED
- Commit: 18c6997ac1bc1d5c22477660d88239e2a17f628c

## Task 1 Fix Round 1
- Replaced bytes.lines with manual byte-level accumulator (DoS-safe)
- Added per-event 1 MB payload cap on multi-line data: accumulation
- Build: SUCCEEDED
- Commit: 276064f

## Task 2: TabKind + folder scan helper
- Added `enum TabKind { case file; case insight(InsightSession) }` to DocumentState.swift, `var kind: TabKind = .file` field on `OpenTab` (default preserves source-compat for both existing call sites at WorkspaceManager L727 and L1212).
- Created `MarkView/Models/InsightSession.swift` placeholder stub (`@MainActor final class InsightSession: ObservableObject, Identifiable`) — real implementation lands in Task 4. Registered new file in MarkView.xcodeproj/project.pbxproj (PBXBuildFile + PBXFileReference + Models group + Sources build phase).
- Added `scanMarkdownFiles(in:) -> Result<[URL], ScanError>` helper, `var hasMarkdownFiles: Bool` computed property, and `enum ScanError: Error, LocalizedError { case folderTooLarge(count:limit:) }` to WorkspaceManager. Helper enforces tech-spec Decision 10 §7: `.skipsHiddenFiles` + `.skipsPackageDescendants`, `.md` ext + `.dde` exclusion, symlink containment via `resolvingSymlinksInPath().standardizedFileURL` (resolve-then-standardize order), 500-file cap with immediate stop on overflow. `hasMarkdownFiles` short-circuits on first match for menu responsiveness.
- Existing three enumerator sites (excludeFolder L553, extractWithOllama L930, analyzeAllFiles L1564) deliberately left untouched per task scope.
- Build: SUCCEEDED, 0 errors, 0 warnings in modified files.
- Commit: 94f3a400a4bfbf90d599bc9185094e61d469c95a

## Task 2 Fix Round 1
- Fixed hasPrefix sibling-prefix bypass in scanMarkdownFiles symlink containment check (added path separator)
- Build: SUCCEEDED
- Commit: bb828a9

## Task 5: Insight mode in WebView (HTML/JS)
- Added state.mode === 'insight' branch with split-pane layout (top breadcrumbs / center markdown / right deep-dive list with error banner above / bottom Save+Up buttons), CSP `<meta>` tag in <head> with the exact directives from Decision 10 §3, and a separate `insightMd` markdown-it instance configured with `html: false` + link-target sanitizer rejecting `javascript:`/`data:`/`file:`/`vbscript:`/unknown schemes (the existing global `md` with `html: true` is untouched). All LLM-derived strings flow through a single `setText(el, str)` utility that uses `textContent` only — no `innerHTML` on LLM data.
- Marker parser implements `\n\n---DEEP-DIVES---\n` boundary form, `lastIndexOf` semantics (last marker wins), tolerant per-line split `- <Label> :: <hint> :: <scope_hint>` (missing `::` segments default to empty). Per-block Mermaid pipeline replaces each `pre code.language-mermaid` with a `.mermaid` div and runs `mermaid.run({ nodes: [singleNode], suppressErrors: false, securityLevel: 'strict' })` inside its own try/catch — failed blocks restored as raw `<pre><code>` plus an `.insight-mermaid-error` label. Rendering is debounced (~150 ms) via `clearTimeout` + `setTimeout(renderInsight, 150)`.
- 5 window functions implemented (`loadInsightView`, `appendInsightDelta`, `setInsightDeepDives`, `showInsightLoading`, `setInsightError`) defensively `JSON.parse` string args. 5 button click types posted via existing `sendToSwift` bridge with EXACT type names: `insightSaveRequested`, `insightUpClicked`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRetryRequested`. Mode-switching paths (`switchToPreview`/`Source`/`StructuredView`/`StructuredSource`) updated to call `leaveInsightView()`; `toggleMode` and `toggleModeWrapper` short-circuit when `state.mode === 'insight'`.
- 5 marker fixtures committed under `Tests/Fixtures/marker-cases/` — `happy.md`, `in-code-fence.md`, `as-hr.md`, `no-marker.md`, `multiple-markers.md` — each prefixed with an HTML comment documenting the expected parser output for code-reviewer hand-trace per Decision 9.
- Build: SUCCEEDED. Verify-user (poisoned-markdown XSS smoke test) deferred to Tasks 6/7/8 wiring — there is no JS surface to trigger the insight pipeline from the running app yet.
- Commit: 33cba9d

## Task 5 Fix Round 1
- Widened CSP directive to allow existing CDN domains (script-src/style-src https://cdn.jsdelivr.net) and remote https images (img-src https:). Round 1 review found the global <meta> CSP from Decision 10 §3 was applied document-wide and blocked four CDN scripts (D3, dagre, turndown, turndown-plugin-gfm) plus remote markdown images used by existing modes (preview, structured, WYSIWYG-save).
- Insight-mode security intent preserved via markdown-it `html: false`, `setText` utility (textContent only), `connect-src 'none'`, `object-src 'none'`, `base-uri 'none'`.
- Mermaid `securityLevel: 'strict'` still applied per-render (and via `initialize()` on insight-mode entry); minor cleanup of redundant `securityLevel` arg on `mermaid.run()` deferred — auditor confirmed protection still works and the prompt explicitly allowed leaving it as-is when shared with global mermaid.
- Final CSP directive: `default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; connect-src 'none'; img-src 'self' data: https:; object-src 'none'; base-uri 'none'`
- Build: SUCCEEDED
- Commit: 7db0ae9

## Task 3: Extend GraphRAG with folder map-reduce
- Added mapReduceForFolder(folderURL:mdFiles:question:onDelta:) using parallel map (no-op streaming via streamCompletion) + streaming reduce
- Decision 5 thresholds applied: 50 KB per-file truncation, 200 KB per-community subdivision
- Decision 10 §5 XML-tag instruction isolation in both map and reduce system prompts
- Existing deepResearch() and callLLM() untouched
- Build: SUCCEEDED
- Commit: f87e1c613485ab8fb75ae892fb9455c64e9d7ed8

## Task 3 Fix Round 1
- Escape literal </file> in body to block prompt injection breakout
- Percent-encode path attribute (handles all XML metacharacters bulletproof)
- Cap concurrent map calls to 5 (rate-limit + resource safety)
- Apply .resolvingSymlinksInPath().standardizedFileURL + path-separator hasPrefix containment (matches T2 fix bb828a9)
- Cancellation propagated, no partial reduce
- Build: SUCCEEDED
- Commit: e4da9bd

## Task 3 Fix Round 2
- Fixed regex template under-escaping (2 backslashes → 4 in Swift source) so escapeXMLEnvelopeBreakout actually rewrites </file> and </community>
- Tightened attribute encoding CharacterSet to exclude & ' " < > explicitly (added Self.xmlAttrSafeCharacters)
- Hand-trace verified: escapeXMLEnvelopeBreakout("a</file>b") = "a<\/file>b" (10 chars: a, <, \, /, f, i, l, e, >, b) — substring "</file>" no longer present
- Build: SUCCEEDED
- Commit: b040692
