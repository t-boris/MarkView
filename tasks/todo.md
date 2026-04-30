# MarkView — Follow-up Tasks

## Pending after Recursive Insight

- [ ] **Set up XCTest infrastructure for MarkView**
  - **Why:** Project has no test target. `Tests/` folder is empty, `project.yml` defines only the `MarkView` app target. No `import XCTest` anywhere.
  - **What to do:**
    1. Edit `project.yml` to add a `MarkViewTests` target (`type: bundle.unit-test`, `platform: macOS`, `sources: [Tests]`, `dependencies: [MarkView]`).
    2. Run `xcodegen` to regenerate `MarkView.xcodeproj`.
    3. Add a test scheme so `xcodebuild test -scheme MarkView` works.
    4. Update `install.sh` / CI to run `xcodebuild test`.
    5. Retroactively cover Recursive Insight critical paths:
       - `Tests/InsightSSEParserTests.swift` — Anthropic SSE byte stream parsing (mock chunked streams, partial chunks, malformed events).
       - `Tests/InsightMarkerParserTests.swift` — `---DEEP-DIVES---` marker detection (avoid false positives on horizontal rules in markdown body).
       - `Tests/InsightSessionTests.swift` — tree lifecycle: createRoot → expandDeepDive → navigateBack → cancel → memory release.
       - `Tests/GraphRAGFolderMapReduceTests.swift` — new `mapReduceForFolder` method on real .md fixtures.
       - `Tests/InsightScopeHintValidationTests.swift` — path-traversal rejection (per Decision 10 §6).
       - `Tests/InsightCancellationRaceTests.swift` — close-tab-during-stream race; verify `Task.isCancelled` observed and no writes to orphaned session.
       - `Tests/InsightResourceCapTests.swift` — verify 50 KB/file truncation, 500 files/folder reject, 10 MB/node cap, 50 MB/session eviction.
  - **When:** Within 2 weeks after Recursive Insight feature is merged (target: 2026-05-14).
  - **Owner:** Boris (or first contributor to touch insight code path post-merge).

- [ ] **Address security carry-over items from Recursive Insight tech-spec validation**
  - **Why:** Security audit r1 raised these as MEDIUM/LOW, deferred outside the Recursive Insight scope but should be resolved before broader release.
  - **Items:**
    1. **WKWebView preference audit** — explicitly verify `WKWebViewConfiguration.preferences.javaScriptEnabled` only where needed, set `webView.configuration.preferences.setValue(false, forKey: "allowFileAccessFromFileURLs")` and `"allowUniversalAccessFromFileURLs"` to harden against local-file XSS.
    2. **Audit logging for AI calls** — log model, token counts (already done), but also LLM call source (which feature/tab triggered it) for cost attribution and abuse forensics.
    3. **Pin markdown-it and mermaid versions** — currently CDN-loaded without integrity hashes. Add SRI hashes or vendor in `Resources/Editor/` and pin specific versions. Mermaid ≥ 10, markdown-it ≥ 13.
  - **When:** Before next major release of MarkView, not tied to Recursive Insight.
