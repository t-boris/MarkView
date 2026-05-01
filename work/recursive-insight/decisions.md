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
