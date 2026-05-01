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
