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

## Task 4: Create InsightSession and node tree (real implementation)
- Replaced stub; real @MainActor class with InsightNode tree, all 11 methods (generateRoot, expand, navigateTo, up, cancel, retryCurrent, currentNode, breadcrumbs, snapshot, handleStreamError + scope_hint validator)
- @Published: rootNode, currentNodeId, streamingBuffer, isStreaming, lastError, lastErrorRetryable
- Decision 11 §1: all long-lived closures use [weak self] with guard let self else { return }; outer Task closure + inner onDelta hop both weak
- Decision 11 §3: handleStreamError pattern-match table for all AIProviderError cases (noAPIKey/invalidResponse/httpError 429+5xx/httpError other/parseError/streamingError + CancellationError silent + unknown default retryable); retry throttle 3/60s with lastErrorRetryable propagation; window resets on successful retry
- Decision 10 §6: scope_hint resolved with .resolvingSymlinksInPath().standardizedFileURL (resolve BEFORE standardize); path-separator-aware containment (trailing-slash hasPrefix per T2 fix bb828a9); .md extension required; rejected entries logged via NSLog
- Decision 10 §7: 10 MB per-node cap enforced inside appendStream → cancels stream + node.failed; 50 MB per-session cap with oldest-non-current-path eviction (sort by generatedAt asc, ties by level desc, unlinks from parent.children)
- Decision 10 §5: XML-tag isolation in system prompt; literal </file> escaped via 4-backslash Swift pattern (Swift "<\\\\/file>" → in-memory <\\/file> → NSRegularExpression template emits <\/file> with one literal `\`); reuses GraphRAG xmlAttrSafeCharacters subtraction approach for path attribute percent-encoding
- Decision 5: ≤30 files → streamCompletion direct; >30 → graphRAG.mapReduceForFolder; 50 KB per-file truncation in wrapFile; 30-file cap on deep-dive expansion
- Marker parser: range(of:options:.backwards) finds LAST `\n\n---DEEP-DIVES---\n`; tolerates 0 topics; skips malformed lines (NSLog warning)
- Hand-trace verified again locally: escapeXMLEnvelopeBreakout("a</file>b") output bytes [97,60,92,47,102,105,108,101,62,98] — backslash 0x5C is between `<` and `/`, substring "</file>" absent from output
- Build: SUCCEEDED, 0 warnings, 0 errors
- Commit: 0473f8a3d1766b06270baad867a06a3510c03900

## Task 4 Fix Round 1
- handleStreamError now takes forNodeId param — tracks erroring node correctly even after expand
- Explicit error on graphRAG=nil + mdFiles>30 (instead of silent fallback to context overflow)
- Deep-dive scope_hint capped at 30 files via path-distance ranking from parent anchor
- appendStream MainActor hop checks Task.isCancelled + status before appending
- apiKeySnapshot mid-session rotation documented as known limitation (design choice)
- Retry throttle: counts cancelled+completed in 60s window; resets only on .ready
- Build: SUCCEEDED
- Commit: 62b8bff

## Task 6: WebViewBridge insight + EditorView routing
- Added 5 Swift→JS commands (loadInsightView, appendInsightDelta, setInsightDeepDives, showInsightLoading, setInsightError)
- Added 5 JS→Swift message types + delegate methods (insightDeepDiveClicked, insightSaveRequested, insightBreadcrumbClicked, insightUpClicked, insightRetryRequested)
- EditorView.loadContentIfNeeded branches on tab.kind; pendingTab cache for 2nd call site at didFinish (and 3rd at bridgeEditorReady)
- Combine: $streamingBuffer (delta forward via String(newBuffer.dropFirst(lastForwardedLength)) with reset-detection on shrink), $currentNodeId (full repaint with lastForwardedLength reset BEFORE on .receive(on: .main)), $lastError (forward with session.lastErrorRetryable, never hardcoded)
- All Swift→JS payloads use array-wrap encoding idiom via private encodeStringForJS helper; bool serialised as literal "true"/"false"; snapshot/topics encoded via JSONEncoder
- Coordinator delegate stubs (NSLog) — Task 7 will fill in WorkspaceManager forwarders
- Build: SUCCEEDED, 0 warnings in WebViewBridge.swift / EditorView.swift
- Commit: f33ea0a

## Task 6 Fix Round 1 (cross-task fix landing in InsightSession.swift)
- snapshot().markdown now returns body portion of rawBuffer for .streaming/.failed nodes (was: empty markdownBody until .ready)
- Tab-switch back during streaming preserves visible buffer (Decision 11 §5)
- Build: SUCCEEDED
- Commit: 86c07f0

## Task 7: WorkspaceManager insight wiring + EditorView Coordinator delegate bodies
- startRecursiveInsight: scan → InsightSession → OpenTab(.insight) → Task { generateRoot }
- closeTab: insight branch cancels session BEFORE removeTab (Decision 11 §4)
- 5 forwarder methods (deepDive, save, breadcrumb, up, retry) + findInsightSession scan
- saveInsightNode: NSSavePanel, sanitized filename, .md extension forced
- EditorView.Coordinator: 5 NSLog stubs replaced with parent.workspaceManager forwarders
- Build: SUCCEEDED
- Commit: 73ce507d2163f3d9af703b800fc50298f9385647

## Task 7 Fix Round 1
- Critical: added insight-tab early-return guards in all save/refresh paths to enforce "never written to disk" invariant (saveActiveFile, saveFile, reloadActiveTabFromDisk, openOrRefreshFile refresh-branch, updateActiveTabContent, reindexActiveFile single-file branch, handleBlocksDelta, plus pre-hop guards in EditorView Coordinator bridgeSaveRequested / bridgeRefreshRequested)
- Major: sanitizeInsightFilename now strict ASCII [A-Za-z0-9_] via Set<Character> (was Unicode-aware Character.isLetter/isNumber)
- Major: UTType safe unwrap (no force-unwrap crash); also added explicit `import UniformTypeIdentifiers`
- Major: sanitizeForLog strips \r\n\0 and truncates to 64 chars; all 5 bridge forwarders now log via %@ format specifier instead of string interpolation
- Minor: documented sandbox-OFF dependency in saveInsightNode header (re-enable would require startAccessingSecurityScopedResource on folderURL/pickedURL); documented Task @MainActor pattern as deliberate match to surrounding bridge idiom; save-feedback-loop NSAlert warning when user saves inside the analyzed folder
- Code review: unused `fromSession` param now used — analyzed-folder name (recovered from the owning tab's placeholder URL since InsightSession.folderURL is private and we did not widen its access from outside InsightSession.swift) prefixes the default filename and drives the in-folder warning
- Build: SUCCEEDED, 0 warnings/errors in WorkspaceManager.swift or EditorView.swift
- Commit: aaee2201e51928bec2bf7dc464310e70b0521fbc

## Task 8: AI Tools menu integration
- Added Button "🧭 Recursive Insight" to Section("Analysis") after "Generate Full Documentation"
- Wired to workspaceManager.startRecursiveInsight()
- .disabled(rootNode == nil || !hasMarkdownFiles)
- Build: SUCCEEDED
- Commit: bef9874

## Task 9: Code Audit
- Verdict: APPROVED_WITH_FIXES
- 18 findings (0 critical, 1 major, 8 minor, 9 info). Major: M1 — bridge messages lack node-id payload, races possible if user navigates between deep-dive click and Task @MainActor execution.
- Hand-trace SSE parser: ok (26 onDelta calls reconstruct expected text from sse-anthropic-sample.txt; oversized-line / event-payload / error-event paths verified by code inspection only — flagged as fixture coverage gap for deferred tests).
- Hand-trace marker parser: ok per fixture (happy ✓, in-code-fence ✓ via lastIndexOf, as-hr ✓, no-marker ✓, multiple-markers ✓ — Swift parseMarker and JS parseInsightMarker produce identical outputs for all 5).
- Shared resources: 1 AIProviderClient (AIOrchestrator.swift:32), 2 GraphRAG (both pre-existing in WorkspaceManager) — feature added zero new instances. All 15 long-lived closures in InsightSession use [weak self] + guard pattern.
- Report: logs/audit/code-audit.md

## Task 10: Security Audit
- Verdict: APPROVED
- 5 findings (0 critical, 0 high, 2 medium, 3 low) — all medium/low items are pre-existing or acknowledged limitations, not introduced by Recursive Insight
- Layer verification: 7/7 layers shipped correctly (markdown-it html:false + link sanitizer; setText for all LLM strings; CSP meta exact match to post-T5-r1 spec; Mermaid securityLevel:strict per-render; XML isolation in both InsightSession + GraphRAG prompts; scope_hint .resolvingSymlinksInPath().standardizedFileURL containment + .md ext check; all caps 50KB/500/10MB/50MB/64KB-line/1MB-event/3-retries/5-concurrent enforced)
- escapeXMLEnvelopeBreakout hand-trace: ok in BOTH InsightSession.swift:1056 and GraphRAG.swift:554 — input `a</file>b` → output bytes `[97,60,92,47,102,105,108,101,62,98]` (`a<\/file>b`), substring `</file>` absent (no T3-r2 regression)
- API key leak grep: clean for Recursive Insight surface (sanitize at AIProviderClient L421-424 + apiKeySnapshot redaction at InsightSession L700-702 + sanitizeForLog with %@ format specifier in WorkspaceManager bridge forwarders); 3 non-streaming pre-existing throw sites flagged as M1 (out of scope)
- 9 insight-tab disk-write guards + 2 EditorView pre-hop guards verified (Check 10)
- NSSavePanel sanitization: strict ASCII [A-Za-z0-9_] (post-T7-r1 fix) + .md extension forced (Check 9)
- Report: logs/audit/security-audit.md
