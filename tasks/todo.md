# MarkView — Follow-up Tasks

## Pending after Recursive Insight (v2)

- [ ] **Set up XCTest infrastructure for MarkView**
  - **Why:** Project has no test target. `Tests/` folder is empty, `project.yml` defines only the `MarkView` app target. No `import XCTest` anywhere.
  - **What to do:**
    1. Edit `project.yml` to add a `MarkViewTests` target (`type: bundle.unit-test`, `platform: macOS`, `sources: [Tests]`, `dependencies: [MarkView]`).
    2. Run `xcodegen` to regenerate `MarkView.xcodeproj`.
    3. Add a test scheme so `xcodebuild test -scheme MarkView` works.
    4. Update `install.sh` / CI to run `xcodebuild test`.
    5. Retroactively cover Recursive Insight v2 critical paths (per Decision 9 — tests deferred until XCTest infrastructure exists; the eight v2 paths below are the canonical first tests for this feature):
       - [ ] `Tests/InsightToolCallParsingTests.swift` — Anthropic `tool_use` envelope parsing in `GraphRAG.buildSkeleton`. Verify strict-schema `InsightSkeleton` decoding, fallback to a single-prose-section `InsightSkeleton` on schema violation, and unique `section.id` / `deepDiveTopic.id` enforcement.
       - [ ] `Tests/InsightPostMessageTests.swift` — `WebViewBridge` postMessage dispatch: 5-type allowlist (`insightIframeReady`, `insightDeepDiveClicked`, `insightBreadcrumbClicked`, `insightRequestSave`, `insightRequestUp`), per-type payload schema validation (presence + non-empty + Int bounds + UUID shape), `frameInfo.isMainFrame` guard, and parent JS `event.source` / `event.origin === 'null'` defense.
       - [ ] `Tests/InsightCacheCRUDTests.swift` — `InsightCache` atomic `writeNode` / `readNode`, `updateManifest` / `loadManifest` (UUID-suffixed temp + `replaceItemAt` swap), concurrent-writer collision avoidance, `cleanup()` ENOENT tolerance, path-containment guard against symlink escape.
       - [ ] `Tests/InsightArchiveExporterTests.swift` — ZIP staging dir builder + HTML rewriting (deep-dive `<button data-section-id=…>` → `<a href="<uuid>.html">`, breadcrumb `href="#<uuid>"` → relative file href, lib refs `../_assets/` ↔ `_assets/` for root promotion), Decision 10 escape policy enforcement at every interpolation, and `Process` argument-array safety against shell-metacharacter destination filenames.
       - [ ] `Tests/InsightBlobLifecycleTests.swift` — Lazy `URL.createObjectURL` materialisation per skeleton section types (Mermaid/Chart/KaTeX gated on `section.type` / `metadata.hasMath`), revocation on navigation between nodes with different lib subsets, and full revocation on tab close via `window.releaseInsightBlobs()`.
       - [ ] `Tests/InsightPhase2ParallelismTests.swift` — `withThrowingTaskGroup` cap of exactly 5 concurrent section streams enforced (additional sections wait for a slot; group never exceeds the cap even under burst).
       - [ ] `Tests/InsightIframeCSPTests.swift` — Iframe `srcdoc` CSP correctness: `sandbox="allow-scripts"` (no `allow-same-origin`, `allow-popups`, `allow-forms`, `allow-modals`, `allow-top-navigation`), `<meta http-equiv="Content-Security-Policy">` present with `default-src 'self' 'unsafe-inline' blob: data:` + `img-src * data: blob:` + `font-src * data:`.
       - [ ] `Tests/InsightIframeTimeoutTests.swift` — 10 s no-`insightIframeReady` watchdog: parent JS calls `setInsightError(message, retryable: true)` and tears down the iframe; retry path re-issues the load.
  - **When:** Within 2 weeks after Recursive Insight v2 is merged.
  - **Owner:** Boris (or first contributor to touch insight code path post-merge).

- [ ] **Address security carry-over items from Recursive Insight tech-spec validation**
  - **Why:** Security audit r1 raised these as MEDIUM/LOW, deferred outside the Recursive Insight scope but should be resolved before broader release.
  - **Items:**
    1. **WKWebView preference audit** — explicitly verify `WKWebViewConfiguration.preferences.javaScriptEnabled` only where needed, set `webView.configuration.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")` and `"allowUniversalAccessFromFileURLs"` to harden against local-file XSS.
    2. **Audit logging for AI calls** — log model, token counts (already done), but also LLM call source (which feature/tab triggered it) for cost attribution and abuse forensics.
    3. **Pin markdown-it and mermaid versions** — currently CDN-loaded without integrity hashes. Add SRI hashes or vendor in `Resources/Editor/` and pin specific versions. Mermaid ≥ 10, markdown-it ≥ 13.
  - **When:** Before next major release of MarkView, not tied to Recursive Insight.
