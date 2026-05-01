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
