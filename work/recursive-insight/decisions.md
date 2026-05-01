# Decisions Log: Recursive Insight v2 (Insight Web)

Per-task summaries (1-3 sentences) + commit refs + key decisions.

---

## Task 1: AIProviderClient.toolCall
- Implemented toolCall(name:description:inputSchema:systemPrompt:userMessage:model:maxTokens:)
- Anthropic Messages API + tools field; sanitize discipline mirrors streamCompletion L251
- Fixture: synthetic at Tests/Fixtures/insight-skeleton-sample.json (no ANTHROPIC_API_KEY in env; structurally faithful to InsightSkeleton + Anthropic envelope)
- Build: SUCCEEDED
- Commit: 66829ad

## Task 3: InsightCache module
- New MarkView/Models/InsightCache.swift with atomic write/read, manifest CRUD, cleanup, archiveStagingDirectory (async)
- Path validation duplicated from WorkspaceManager (no cross-class coupling)
- pbxproj registered in Sources phase
- Build: SUCCEEDED
- Commit: d0f28f0

## Task 2: Vendor Chart.js + libs MANIFEST
- Chart.js 4.4.9 vendored at vendor/js/chart-4.4.9.min.js, SHA-256 verified (bce15408...c844)
- MANIFEST.txt covers all 50 vendored assets: chart.js, mermaid (10.6.1), katex+auto-render (0.16.9) + 20 webfonts, prismjs core + 16 plugins (1.29.0) + 3 css, markdown-it (13.0.1), markdown-it-footnote (3.0.3), markdown-it-task-lists (2.1.1), markdown-it-container (4.0.0), js-yaml (4.1.0)
- CVE check (2026-04-30 via GitHub Advisories): chart.js/markdown-it family/js-yaml clean; katex 0.16.9 has 5 known CVEs (patched 0.16.10/0.16.21), prismjs 1.29.0 has 1 known CVE (patched 1.30.0), mermaid 10.6.1 has 3 known CVEs — all risks accepted with rationale recorded in MANIFEST (sandboxed iframe, no untrusted DOM context); upgrades scheduled separately
- pbxproj NOT edited (existing "Build Web Editor (optional)" Run Script ditto-copies entire vendor/ — verified chart-4.4.9.min.js + MANIFEST.txt present in built MarkView.app/Contents/Resources/Editor/vendor/)
- Build: SUCCEEDED
- Commit: a2866be

## Wave 1 Fix Round 1
- T3 InsightCache: manifest tmp UUID-suffixed (concurrency safety), replaceItem for atomic update, archiveStagingDirectory tautology fixed, Bundle API idiom corrected
- T2 MANIFEST: Mermaid CVE attribution corrected (only DOMPurify CVE applies to 10.6.1), sandbox mitigation language clarifies pre-v2 vs post-v2
- Build: SUCCEEDED
- Commit: c00ae48

## Task 4: GraphRAG v2 prompts + InsightModels.swift
- Caller inventory (grep `mapReduceForFolder` MarkView/): only InsightSession.swift (L102 comment, L171 comment, L219 call, L414 call) + definition at GraphRAG.swift L233. No third-party callers — additive-only path safe.
- Added MarkView/Models/InsightModels.swift with InsightSkeleton, InsightSection, SectionType (with allCaseStrings helper for schema), InsightDeepDiveTopic, SectionState. **Deviation:** v2 spec asks for `DeepDiveTopic` and `AnyCodable` types. Both already exist in v1 with INCOMPATIBLE shapes (v1 `DeepDiveTopic.id: UUID`, v1 `AnyCodable` is enum in WebViewBridge.swift). To keep build green between T4 and T6, the v2 type is named `InsightDeepDiveTopic` (will rename to `DeepDiveTopic` in T6 cleanup after v1 InsightSession.swift is deleted), and the existing `AnyCodable` enum from WebViewBridge.swift is reused for `InsightSection.metadata` (single canonical type, avoids drift).
- Added GraphRAG.buildSkeleton (toolCall + parse + fallback skeleton on schema violation, sanitized NSLog, no dict logging) and buildSectionPrompt (sync helper, type-specific lookup table for 9 SectionType cases, scopeHint validation: nil=all files, []=explicit none, traversal/out-of-folder paths rejected with NSLog warning, dedup).
- Phase 1 user message: single `<files>` envelope (no community grouping for skeleton — model has full folder view via `<file path=...>` attrs). Each cluster chunk wrapped in `<community name="files (chunk i/N)">` only when 200KB cap forces split.
- Empty folder edge case: returns fallback InsightSkeleton (one prose section "No files to analyze") instead of throwing — UI still renders something.
- mapReduceForFolder kept intact byte-for-byte (additive-only strategy per task spec). v1 InsightSession still uses it until T6. `git diff` shows zero deletions in GraphRAG.swift.
- deepResearch / summarizeCommunities / callLLM / fnv1a unchanged (verified by `git diff` — zero `-` lines).
- escapeXMLEnvelopeBreakout / xmlAttrSafeCharacters reused in both buildSkeleton and buildSectionPrompt (13 grep callsites total in GraphRAG.swift, was 7 before).
- InsightModels.swift registered in MarkView.xcodeproj/project.pbxproj (PBXBuildFile + PBXFileReference + Models group + PBXSourcesBuildPhase, IDs F55…/F66… following the existing F-prefix convention).
- Build: SUCCEEDED, 0 errors, 0 new warnings in GraphRAG.swift / InsightModels.swift.
- Commit: bc2728b

## Task 5: index.html v2 insight-mode (iframe + postMessage + skeleton)
- v1 insight-mode JS REMOVED (parseInsightMarker, processInsightMermaidBlocks, loadInsightView, appendInsightDelta, setInsightDeepDives, showInsightLoading, v1 setInsightError, insightMd, INSIGHT_MARKER, setInsightErrorBanner, scheduleInsightRender, renderInsightDeepDivesFromArray, initInsightButtons, insight-error-banner / insight-deep-dives-list / insight-button-row DOM, all v1 split-pane CSS); v1 state fields (insightBufferText, insightDeepDives, insightBreadcrumbs, insightIsStreaming, insightLastError, insightRenderTimer) replaced.
- v2 added: iframe sandbox="allow-scripts" (no allow-same-origin/popups/forms/modals/top-navigation), iframe srcdoc CSP per Decision 10, 5 window.* setters (loadInsightSkeleton, updateInsightSection, setInsightError, setInsightStatus, releaseInsightBlobs), 5 postMessage allowlist (insightIframeReady, insightDeepDiveClicked, insightBreadcrumbClicked, insightRequestSave, insightRequestUp) with event.source/origin + per-type payload schema validation (UUID regex for breadcrumb nodeId, sectionId membership + topicIndex bounds for deep-dive), lazy blob URL libs (Prism unconditional; Mermaid/Chart/KaTeX gated by section.type / metadata.hasMath), KaTeX webfont base64 inlining, 10s iframe-ready timeout with teardown, escapeForHTMLAttribute/escapeForHTMLText utility (sole HTML interpolation path), CDN strip regex (script src=https/// + link rel=prefetch/preconnect/dns-prefetch → HTML comment), per-section pending-chunks buffer flushed on iframe ready.
- Existing modes (source, preview, structured, structured-source) untouched; global markdown-it `md` instance untouched.
- Stale doc comment at file head referencing v1 insightMd updated to describe v2 iframe isolation model.
- Static-grep gates: sandbox="allow-scripts" present (2 hits — static element + JS setter), CSP meta present, 0 forbidden sandbox flags, 5 setters / 5 message types greppable, escapeForHTMLAttribute + escapeForHTMLText defined, createObjectURL/revokeObjectURL used, ZERO v1 leftover names.
- Build: SUCCEEDED.
- Deviation: spec L44 mentions a Retry button posting `insightRequestUp` for retryable errors; the 5-type allowlist forbids a 6th type. Implementation surfaces retryability only via status-bar message text ("— retry by re-invoking action") — TODO comment in code flags this for T6/T7 owner. Adding `insightRequestRetry` would require user approval (would change allowlist count from 5 → 6).
- Note: between T5 and T7, v1 Bridge methods (Swift) call removed JS funcs → runtime ReferenceError if insight is invoked; T7 fixes by replacing the bridge surface with the v2 setters. Build itself is green.
- Commit: b3d688f

## Task 6: InsightSession v2 rewrite
- InsightSession.swift fully rewritten (1260 lines, was 1073)
- Uses `graphRAG.buildSkeleton(...)` (T4) for Phase 1, `graphRAG.buildSectionPrompt(...)` (T4) for Phase 2 prompt composition, `providerClient.streamCompletion(...)` for streaming, `InsightCache` (T3) for atomic node + manifest writes
- Types from InsightModels.swift (T4): InsightSkeleton, InsightSection, SectionType, InsightDeepDiveTopic, SectionState, AnyCodable — all referenced by name only, NOT redeclared
- 5 spec types declared in file: enum NodeScope (Codable), struct BreadcrumbEntry, struct InsightViewSnapshot (v2 shape with skeleton instead of markdown+deepDives), final class InsightNode (Codable, with sectionStates instead of rawBuffer/markdownBody/deepDives), @MainActor final class InsightSession. + 1 internal enum InsightSessionError (cacheWriteFailed) per task spec edge case 4.
- 10 @Published fields per spec: rootNodeId, currentNodeId, nodes, lastError, lastErrorRetryable, currentNodeSections, skeleton, skeletonReady, allSectionsReady, statusMessage. Plus cachedNodeHTML (for navigateTo cache-read result, mentioned in step 12) and 2 v1-compat shims (streamingBuffer, isStreaming) — empty placeholders so EditorView's v1 subscriptions still type-check until T7 rewrites them.
- Phase 2 cap=5 via withThrowingTaskGroup with gated scheduling (per pattern from GraphRAG.mapReduceForFolder v1)
- Per-section prompts pre-built on MainActor before launching off-actor section tasks (because GraphRAG is @MainActor)
- Preserved verbatim from v1: handleStreamError 8-case pattern table (CancellationError silent, AIProviderError cases, generic), retry throttle 3/60s sliding window per node, validateScopeHint with strict resolvingSymlinksInPath().standardizedFileURL order + path-separator containment + .md extension check, resource caps (per-node 10MB rawBuffer, per-session 50MB with eviction of oldest non-current-path nodes by generatedAt + level desc), per-final-HTML 2MB cap (tech-spec acceptance), apiKeySnapshot capture in init body + redaction in handleStreamError, [weak self] in every long-lived closure (7 instances)
- writeFinalHTMLToCache: deterministic rebuild via static buildHTMLTemplate (skeleton + sectionStates + breadcrumbs + lib refs), HTML-escape utility (escapeForHTML) applied to all LLM-controlled strings (skeleton.title, section.title, deep-dive label/hint, scopeHint paths displayed). NOT iframe round-trip.
- Async signatures: cancel() async (awaits activeTask.value for serialised cleanup), navigateTo(nodeId:) async (cache.readNode I/O), up() async (delegates), expand(sectionId:topicIndex:) async, retryCurrent() async, generateRoot() async
- Manifest update: load-or-init, dedupe by nodeId, append, atomic write via cache.updateManifest
- WebViewBridge v1 insight methods stubbed (NSLog no-ops): loadInsightView, appendInsightDelta, setInsightDeepDives, showInsightLoading, setInsightError. Signatures retained so EditorView Coordinator + WorkspaceManager forwarders compile. T7 fully replaces with v2 setters (loadInsightSkeleton, updateInsightSection, setInsightStatus, releaseInsightBlobs).
- WorkspaceManager touched (build-green coordination): closeTab insight branch wraps cancel() in Task; startRecursiveInsight uses v1-compat throwing convenience init that builds an InsightCache under temp dir; didRequestInsightDeepDive forwarder stubbed (v1 sent only topicIndex; v2 needs sectionId — T7 rewrites bridge handler); navigateTo/up calls wrapped in Task; saveInsightNode body stubbed with placeholder string (v1 markdownBody field is gone — T8 ZIP export replaces).
- Build: SUCCEEDED, 0 warnings in modified files
- Static checks PASSED: `[weak self]` count = 7 (≥4 required), zero `parseMarker`/`---DEEP-DIVES---` regex matches in code (one match in header comment explaining what was removed), `apiKeySnapshot` referenced in init capture + handleStreamError redaction, `resolvingSymlinksInPath` precedes `standardizedFileURL` strictly in validateScopeHint, all 10 @Published fields present
- Deviation 1: extra `enum InsightSessionError` declared in file (per spec edge case 4 — internal cache-write error type, recommended approach)
- Deviation 2: extra v1-compat published shims (`streamingBuffer`, `isStreaming` — both empty placeholders) so EditorView's existing v1 Combine subscriptions remain type-safe until T7 rewrites them. Documented inline.
- Deviation 3: v1-compat throwing convenience init `InsightSession(folderURL:mdFiles:providerClient:graphRAG:)` so WorkspaceManager.startRecursiveInsight keeps building. T7/T8 will rewrite call site to use the 5-arg init with explicit InsightCache.

## Task 7: WebViewBridge v2 + EditorView routing
- v1 stubs replaced with 5 Swift→JS (loadInsightSkeleton, updateInsightSection, setInsightError, setInsightStatus, releaseInsightBlobs)
- 5 JS→Swift handlers (insightIframeReady, insightDeepDiveClicked, insightBreadcrumbClicked, insightRequestSave, insightRequestUp) all with frameInfo.isMainFrame guard (Decision 3, option (b) — explicit guard per case in userContentController)
- EditorView Combine subs: $skeleton, $currentNodeSections (per-key delta + shrink-detection), $lastError, $statusMessage (all weak captures + main queue)
- WebViewBridgeDelegate updated: 5 v1 methods removed, 5 v2 methods added (didReceiveInsightIframeReady, didRequestInsightDeepDive with sectionId, didRequestInsightBreadcrumb, bridgeRequestInsightSave, bridgeRequestInsightUp)
- WorkspaceManager forwarders updated to v2 signatures (T8 will fully implement bodies; T7 wires the new method names so build stays green): didReceiveInsightIframeReady(sessionId:nodeId:), didRequestInsightDeepDive(sessionId:sectionId:topicIndex:) wired to session.expand, didRequestInsightSave/Up no-args resolved via active tab
- Deviation: setInsightStatus retains `phase: String` parameter (spec offered drop option). EditorView derives a coarse phase tag (`phase-1` / `phase-2` / `ready` / `""`) from session.statusMessage via `Coordinator.derivePhaseTag(from:)`, matching parent JS's status-bar tinting expectation in index.html.
- Deviation: sanitizeForLog duplicated into WebViewBridge.swift (private static) rather than extracted to a shared LogSanitizer utility — bridge-side payload validation needs CWE-117 defense and the cross-file coupling is explicit comment for T8 to extract. Same regex + truncation as WorkspaceManager.sanitizeForLog.
- Deviation: didRequestInsightRetry forwarder dropped (no v2 equivalent — JS surfaces retryable=true via status-bar text, retry happens by re-invoking originating action).
- Build: SUCCEEDED, 0 warnings in modified files
- Static checks PASSED: 5 frameInfo.isMainFrame guards (one per v2 case in userContentController dispatch), 0 v1 method/case references, all v2 methods present, Bool serialised as `true`/`false` literal, `lastForwardedSectionLength` declared + reset + per-section update, all 4 routeInsight Combine sinks use `[weak self, weak session, weak webView]`
- Commit: d4b0bf3

## Task 8: WorkspaceManager v2 wiring + ZIP + todo.md
- closeTab insight 4-step ordered: releaseInsightBlobs (via WorkspaceManager.releaseInsightBlobsHook closure wired by EditorView Coordinator on insight routing) → await session.cancel → try? session.cache.cleanup → tabsStore.removeTab; index re-resolved by sessionId after the await so a stale captured index never points at the wrong tab.
- 5 forwarders v2 signature with payload validation: didReceiveInsightIframeReady (log only), didRequestInsightDeepDive (skeleton lookup + section + topicIndex bounds, plus session.expand re-validates), didRequestInsightBreadcrumb (UUID shape + manifest membership), didRequestInsightSave (calls exportInsightArchive), didRequestInsightUp (derives parentId from currentNode and navigates).
- exportInsightArchive: NSSavePanel default `<folder>_insight_<ISO8601-no-colons>.zip`; archiveStagingDirectory snapshot copied to a fresh `NSTemporaryDirectory()/insight-export-<uuid>/` so HTML rewriting does not mutate the live cache; root node promoted to `index.html` with lib refs unshifted to top-level `_assets/`; deep-dive `<button data-section-id=…>` rewritten to `<a href="<childUUID>.html">` (resolved via in-session `(parentId, sectionId, topicIdx) → childId` map built from `child.title == topic.label`); breadcrumb `href="#<uuid>"` rewritten to `nodes/<uuid>.html` / `<uuid>.html` / `../index.html` based on file location; export staging removed in `defer`.
- New InsightArchiveExporter.swift (Process /usr/bin/zip explicit args, withTaskCancellationHandler hook for SIGTERM on cancel, atomic .zip.tmp → final via replaceItemAt; sanitized stderr in error path).
- 9 v1 disk-write/lookup guards verified still active in WorkspaceManager (saveActiveFile, saveFile(at:), reloadActiveTabFromDisk, openOrRefreshFile refresh-branch, updateActiveTabContent, reindexActiveFile single-file branch, handleBlocksDelta-region, findInsightSession lookup, activeInsightSession lookup) + 2 in EditorView (bridgeSaveRequested, bridgeRefreshRequested). `grep -c 'if case .insight' WorkspaceManager.swift` = 11 (9 v1 guards + closeTab branch + new firstIndex re-resolve helper inside closeTab).
- tasks/todo.md rewritten: removed v1-only test names (InsightSSEParserTests, InsightMarkerParserTests, InsightSessionTests, GraphRAGFolderMapReduceTests, InsightScopeHintValidationTests, InsightCancellationRaceTests, InsightResourceCapTests), added 8 v2 paths per Decision 9 enumeration with checkbox items and 1-2 sentence scope each.
- pbxproj: registered MarkView/Models/InsightArchiveExporter.swift via PBXBuildFile (F77…) + PBXFileReference (F88…) + Models PBXGroup + PBXSourcesBuildPhase (F-prefix convention).
- Build: SUCCEEDED, 0 warnings in modified files.
- Deviation 1: spec L60 reads `cache.archiveStagingDirectory()` as the rewriting site; T3 returns rootDirectory unmodified (matches its current implementation), so T8 owns the rewriting. Followed user-instruction override that explicitly assigns the rewriting to T8.
- Deviation 2: HTML rewriting works in a fresh `NSTemporaryDirectory()` copy of the cache root rather than in-place per Decision 4's "no separate copy step" — protects in-app navigation from cache mutation while the user is exporting. Spec accepts in-place; the copy is a safety improvement, not a violation.
- Deviation 3: deep-dive buttons whose (sectionId, topicIndex) has no corresponding child in the in-session tree (user did not expand that topic) are LEFT AS BUTTONS — they become inert in standalone browser by design (no JS handler), rather than being removed.
- Deviation 4: WorkspaceManager.releaseInsightBlobsHook is a plain (non-Published) closure rather than a NotificationCenter route, because the hook captures the EditorView Coordinator's WebView+Bridge weakly and is invoked exactly once per session close.
- Commit: a2971ba

## Task 9: Code Audit
- Verdict: PASS-WITH-FOLLOWUPS
- 14 findings (0 blocker, 4 major, 7 minor, 3 nit). Majors: per-section error isolation in Phase 2, weak CSP in cache-stored HTML, hard-coded `_assets/` lib filenames disagree with vendor, missing KaTeX webfonts in `_assets/`.
- [weak self] discipline: verified — 8 long-lived closures inspected (Task entry points, withThrowingTaskGroup body, onDelta SSE, 4 Combine sinks, releaseInsightBlobsHook); zero violations.
- Hand-traces: tool_use sample → InsightSkeleton parse OK (sample is schema-conforming, 4 sections decode cleanly); ZIP staging OK structurally but emits broken script src refs (k-major-1) and lacks KaTeX webfonts (k-major-2).
- Dead code confirmed: `GraphRAG.mapReduceForFolder` (~305 lines, no production callers post-T6).
- Report: logs/audit/code-audit.md

## Task 10: Security Audit
- Verdict: APPROVED_WITH_FIXES
- 9 findings (0 critical, 0 high, 1 medium, 3 low, 5 info). Medium: SEC-001 log-forgery via LLM-controlled paths/sectionIds in InsightSession.swift (NSLog uses %@ but bypasses sanitizeForLog — CWE-117). Low: pre-existing main-frame CSP allows cdn.jsdelivr.net (legacy, not in v2 path), missing SRI on iframe lib script tags (defense-in-depth), risk-accepted CVEs in KaTeX 0.16.9/Prism 1.29.0/Mermaid 10.6.1 (mitigated by sandbox + securityLevel:strict).
- Layer verification: 7/7 Decision 10 layers shipped (iframe sandbox, frameInfo guard 5/5, blob URL lifecycle, HTML-escape policy, scope_hint validation, escapeXMLEnvelopeBreakout XML isolation, all 6 resource caps + retry throttle).
- escapeXMLEnvelopeBreakout hand-trace: ok (input "a</file>b" → "a<\/file>b" with literal backslash byte 0x5C; round-2 4-backslash regression fix preserved at GraphRAG.swift:1061).
- 11 insight-tab disk-write guards verified (9 in WorkspaceManager + 2 in EditorView) — no v1 regressions.
- ZIP export: /usr/bin/zip via explicit argv array, no /bin/sh -c (Scenario F closed).
- 7 threat-model walkthroughs (A-G) all defeat their attack paths.
- Report: logs/audit/security-audit.md


## Wave 6 Audit Fixes
- T9 #1: lib filenames now resolved dynamically from _assets/ via vendoredLibURL helper
- T9 #2: InsightCache.copyVendoredLibs recursively copies subdirectories (KaTeX fonts now included)
- T9 #3: cached HTML CSP aligned with iframe srcdoc CSP (Decision 10 §3); exported ZIP uses appropriate self-anchored variants
- T9 #4: Phase-2 per-section error isolation — section throws no longer cancel sibling tasks
- T10 SEC-001: sanitizeForLog added to InsightSession, applied to all 6 NSLog sites with LLM-derived strings
- Build: SUCCEEDED
- Commit: 38236f707ff012b752a239f3ec678b0b49343f9b

## Task 11: Test Audit
- Verdict: DEFERRAL JUSTIFIED
- Per-check: 1✓ (todo.md owner + date) / 2✓ (8 v2 paths) / 3✓ (v1-only removed) / 4✓ (T9+T10 findings code-fixed in 38236f7) / 5✓ (T12 12 scenarios sufficient)
- Critical paths uncovered: none
- Report: logs/audit/test-audit.md
- (Audit completed inline by orchestrator due to upstream rate limit; verification used direct file inspection)

## Task 12: Pre-deploy QA
- Programmatic verdict: PASS (8/8 static checks; build green; SHAs verified; storage clean)
- Build: BUILD SUCCEEDED, 0 errors
- 5 static greps (sandbox / frameInfo / setters / message types / zip not /bin/sh): 8/8 PASS (8 categories)
- Anthropic tool_use smoke: SKIPPED (no ANTHROPIC_API_KEY in QA env) — user must rerun before merge
- Manual pending: 12 Instruments leak scenarios + 14 user-spec checkboxes + standalone-ZIP-in-Safari + after-snapshot SQLite check
- Open audit followups: 4 majors + 1 medium ALREADY RESOLVED in commit 38236f7; 6 nit/minor cleanup items deferred (incl. 305-line dead code mapReduceForFolder)
- Recommendation: READY FOR USER VERIFICATION (YELLOW — one caveat: rerun Anthropic curl with API key)
- Report: logs/qa/pre-deploy-qa-report.md

## Polish: Variant A — meaningful progress
- InsightSession.statusMessage updates at 6 lifecycle points: phase 1 start/done, phase 2 start, per-section completion, all-done, retry, nav-cache
- Status bar (chrome, outside iframe) shows concrete stages: "Phase 1: analyzing 12 files...", "Phase 2: 3/5 sections complete (Architecture streaming...)", "✓ Complete"
- Tiny CSS pulse on update if needed (textContent only, no innerHTML)
- Build: SUCCEEDED
- Commit: 4b1379d

## Polish: progress moved into iframe panel
- Added insight-progress-banner inside iframe srcdoc (sticky top, accent color, animated spinner)
- Parent setInsightStatus forwards via postMessage to iframe.contentWindow (parent→iframe direction; 5-type allowlist applies only to JS→Swift)
- Banner fades on phase=ready
- Bottom status bar kept as defense-in-depth
- Build: SUCCEEDED
- Commit: 34815fa
