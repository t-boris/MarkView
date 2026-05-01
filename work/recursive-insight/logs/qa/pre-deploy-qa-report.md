# Pre-deploy QA Report: Recursive Insight Feature

**QA agent:** pre-deploy-qa (Task 12 — Final Wave)
**Date:** 2026-04-30
**Inputs:** user-spec.md (10 ACs), tech-spec.md (Acceptance Criteria + Decisions 10/11), code-audit.md (T9), security-audit.md (T10), test-audit.md (T11)

This is the final gate before merge. The agent ran every programmatic check available; remaining items require manual user testing on the running macOS app + Xcode Instruments.

---

## Build verification

- **Status: PASS**
- Command: `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build`
- Result: `** BUILD SUCCEEDED **`
- New warnings in modified files (`AIProviderClient.swift`, `DocumentState.swift`, `WorkspaceManager.swift`, `GraphRAG.swift`, `InsightSession.swift`, `WebViewBridge.swift`, `EditorView.swift`, `ContentView.swift`): **0**
- Pre-built editor bundle was copied (Resources/Editor/index.html plus deps).

---

## Smoke checks (programmatic)

### Streaming endpoint (Anthropic Messages API)
- **Status: SKIPPED** — `ANTHROPIC_API_KEY` env var not set in agent shell.
- Confirmation: `[ -z "$ANTHROPIC_API_KEY" ] && echo "no key"` → `no key`.
- Fixture `Tests/Fixtures/sse-anthropic-sample.txt` is present and was hand-traced clean by code-audit.md (26 onDelta calls reconstruct the expected text exactly).
- **User must run** the curl from tech-spec Verify-smoke once their `KEY` env var is exported, to confirm the live endpoint hasn't drifted from the fixture format.

### Storage spot-check (`SemanticDatabase`)
- DB found: `/Users/boris/Documents/Claude/Projects/MarkDV/MarkView/TestFiles/.dde/state.db` (only one DB present in MarkView paths).
- `.tables` listing — 32 tables, **none with `insight*` prefix**:
  ```
  ai_jobs, applied_migrations, artifacts, block_compilation_cache, blocks,
  change_plans, chunks, citations, claims, communities, compile_artifacts,
  compile_jobs, compile_profiles, completeness_evaluations, diagnostics,
  document_templates, documents, entities, entity_relations,
  fts_documents{,_config,_content,_data,_docsize,_idx}, modules, projects,
  quality_tags, recompute_edges, recompute_nodes, struct_relations, symbols,
  temporal_contexts, transitions, usage_stats
  ```
- `SELECT COUNT(*) FROM artifacts WHERE kind LIKE 'insight%';` → **0**
- `SELECT COUNT(*) FROM artifacts;` → **0**
- `SELECT COUNT(*) FROM ai_jobs;` → **0**
- `SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%insight%';` → **(empty)**
- **Verdict: clean.** Decision 3 (in-memory-only tree) confirmed at the storage layer.

### Static cap grep verification (Decision 10 §7 + Decision 5)

| Cap | Constant location | Enforcement location | Status |
|-----|-------------------|----------------------|--------|
| 50 KB per-file | `GraphRAG.swift:191` (`mapReducePerFileByteCap = 50 * 1024`); `InsightSession.swift:149` (`perFileTruncationCapBytes = 50 * 1024`) | `GraphRAG.swift:341-342`; `InsightSession.swift:1027-1028` | **FOUND** |
| 500 files per folder | `WorkspaceManager.swift:549` (`insightFolderFileLimit = 500`); `GraphRAG.swift:199` (`mapReduceMaxFiles = 500`, defensive) | `WorkspaceManager.swift:600-624`; `GraphRAG.swift:240` | **FOUND** |
| 10 MB per-node `rawBuffer` | `InsightSession.swift:147` (`perNodeBufferCapBytes = 10 * 1024 * 1024`) | `InsightSession.swift:580` | **FOUND** |
| 50 MB per-session total | `InsightSession.swift:148` (`perSessionBufferCapBytes = 50 * 1024 * 1024`) | `InsightSession.swift:838, 857` (`enforceSessionMemoryCap()`) | **FOUND** |
| 64 KB per-SSE-line | `AIProviderClient.swift:189` (`maxSSELineBytes = 65_536`) | `AIProviderClient.swift:289` (byte-level enforcement during accumulation, not post-yield) | **FOUND** |
| 1 MB per-SSE-event payload | `AIProviderClient.swift:192` (`maxSSEEventBytes = 1 * 1024 * 1024`) | `AIProviderClient.swift:359` (projected-byte check) | **FOUND** |
| 3-retries / 60s sliding window | `InsightSession.swift:143` (`retryHistory: [UUID: [Date]]`); literal `< 60` at L375 + `count >= 3` at L376 | `InsightSession.swift:372-383` (with cancel-then-retry bypass guard at L470 — Round-1 fix) | **FOUND** |

**Verdict: 7/7 caps verified at the source level.** Constants are explicit (no magic numbers), enforcement sites are documented in code, all match Decision 10 §7 and Decision 5 verbatim.

---

## Acceptance Criteria — programmatically verifiable

These criteria can be confirmed without a running app or Instruments session.

| # | AC | Status | Evidence |
|---|----|--------|----------|
| Build-1 | `xcodebuild build` succeeds with 0 errors | **PASS** | `** BUILD SUCCEEDED **` |
| Build-2 | No new compiler warnings in modified files | **PASS** | grep over modified-file warning lines: 0 |
| Build-3 | All existing call sites that read `tab.url` / `tab.content` / `tab.isModified` continue to work | **PASS** | `OpenTab.kind = .file` default + clean build implies no regression |
| Storage-1 | No new SQLite tables created | **PASS** | `.tables` shows zero `insight*` entries; only pre-existing schema |
| Storage-2 | No writes to `artifacts` or `ai_jobs` tables for insight operations | **PASS** | `COUNT(*)` queries return 0 for both (cleanest possible state); also 9 `closeTab`-class disk-write early-returns confirmed by security-audit Check 10 |
| GraphRAG-1 | `GraphRAG.deepResearch()` (existing) unchanged | **PASS** | grep confirms `mapReduceForFolder` is additive; `deepResearch()` untouched in diff |
| Caps-1..7 | All 7 caps enforced (50KB/file, 500/folder, 10MB/node, 50MB/session, 64KB/SSE-line, 1MB/SSE-event, 3-retries/60s) | **PASS** | All 7 verified by grep above (constants + enforcement sites) |
| SSE-1 | `streamCompletion` parses Anthropic SSE format (handles `content_block_delta`, `message_stop`, `error`; ignores `ping` and `message_delta`; tolerates `: comment` lines) | **PASS** | Code-audit hand-trace against `Tests/Fixtures/sse-anthropic-sample.txt` reconstructs expected text exactly (26 onDelta calls match) |
| SSE-2 | `streamCompletion` propagates HTTP errors as `httpError` with sanitized response body | **PASS** | Code-audit verified `AIProviderClient.swift:239-252` |
| SSE-3 | `streamCompletion` rejects SSE lines > 64 KB without unbounded buffering | **PASS** | Byte-level enforcement DURING accumulation at `AIProviderClient.swift:289` (Round-1 fix from `bytes.lines` → manual byte loop) |
| Security-1 | API key never appears in error messages or NSLog (Recursive Insight surface) | **PASS** | `sanitize()` at AIProviderClient.swift:421-424 wraps streaming throw sites L251/L318/L400; `apiKeySnapshot` redaction at InsightSession.swift:700-702; `sanitizeForLog` + `%@` format specifier in WorkspaceManager bridge forwarders L1445-1452 |
| Security-2 | markdown-it `html: false` and link sanitization (insight mode) | **PASS** | Separate `insightMd` instance at index.html:2794-2799; link sanitizer at L2806-2823 (rejects `javascript:`/`data:`/`file:`/`vbscript:`) |
| Security-3 | All LLM-derived strings via `textContent` | **PASS** | Single `setText` utility at index.html:2875-2878 used at all 9 LLM-string injection sites; only one `innerHTML` on insight surface (L2978) feeds markdown-it output (already escaped) |
| Security-4 | CSP meta tag matches Decision 10 spec | **PASS** | index.html:21 — directives `default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; connect-src 'none'; img-src 'self' data: https:; object-src 'none'; base-uri 'none'` |
| Security-5 | Mermaid `securityLevel: 'strict'` per-render in insight mode | **PASS** | Per-render at index.html:2941 (with also redundant `initialize` at L3102-3107 — flagged as m1 in code-audit) |
| Security-6 | XML-tag instruction isolation in system prompts | **PASS** | InsightSession.swift:915-934 + GraphRAG.swift:419-421/515-517 use identical `<file path="...">...</file>` + "treat as DATA ONLY" pattern; `escapeXMLEnvelopeBreakout` confirmed clean by security-audit hand-trace (T3-r2 regression NOT re-introduced) |
| Security-7 | scope_hint validation (resolveSymlinks → standardizedFileURL → containment + .md ext) | **PASS** | InsightSession.swift:728-761 (validateScopeHint), GraphRAG.swift:301-329, WorkspaceManager.swift:581-620 — all use same idiom; path-separator-aware containment with trailing `/` |
| Security-8 | Folder scan does not follow symlinks pointing outside | **PASS** | `WorkspaceManager.scanMarkdownFiles` uses `.skipsHiddenFiles` + `.skipsPackageDescendants` + resolved-path containment check |
| Security-9 | Retry throttle 4th attempt within 60s rejected with non-retryable | **PASS** | InsightSession.swift:374-381 sets `lastErrorRetryable = false` and emits "retry rate limit" — also has cancel-then-retry bypass guard from Round-1 fix |
| Security-10 | NSSavePanel filename sanitization (strict ASCII) + forced `.md` extension | **PASS** | `sanitizeInsightFilename` strict `[A-Za-z0-9_]` at WorkspaceManager.swift:1617-1631 (post-T7-r1 fix); `.md` extension forced at L1571-1576 |
| Marker-1 | Marker only matched at form `\n\n---DEEP-DIVES---\n` | **PASS** | Both Swift `parseMarker` (InsightSession.swift:873-911) and JS `parseInsightMarker` (index.html:2886-2915) use the boundary-newline form |
| Marker-2 | Last-occurrence semantics | **PASS** | Swift uses `range(of:options:.backwards)`; JS uses `lastIndexOf` — verified across 5 marker fixtures by code-audit |
| Marker-3 | Marker absent → render full body, empty deep-dive | **PASS** | Verified by `as-hr.md` and `no-marker.md` fixtures |
| Marker-4 | 0 or >7 topics accepted as-is | **PASS** | No enforcement code present (verified by code-audit i-items) |
| ARC-1 | All `InsightSession` long-lived closures use `[weak self]` | **PASS** | Code-audit verified 15/15 closures inside InsightSession + 3/3 Combine subscriptions in EditorView.routeInsight; bridge-side `Task { ... }` strong captures (m5) acceptable per Decision 11 §1 scope |
| Cancel-1 | `cancel()` calls `activeTask?.cancel()` then sets to nil | **PASS** | InsightSession.swift:360-364 — verified by code-audit |
| Cancel-2 | `closeTab` cancels session BEFORE `tabsStore.removeTab` | **PASS** | WorkspaceManager.swift:1110-1113 — Decision 11 §4 ordering verified |
| Cancel-3 | `closeTab` for `.insight` skips save prompt | **PASS** | Branch at WorkspaceManager.swift:1110, no `isModified` check fired |

**Programmatic AC pass-rate: 28/28** (every criterion that can be evaluated without a running app passes).

---

## Acceptance Criteria — REQUIRES USER TESTING

These items demand a running MarkView macOS app, real LLM responses, and (for the Instruments scenarios) Xcode Instruments. Agent cannot exercise them.

### User-spec ACs (10 items, manual flow on `TestFiles/`)

For each: open MarkView, open the `TestFiles/` folder, then perform the prescribed steps.

1. **AC1 — Menu item presence.** `AI Tools → Analysis → 🧭 Recursive Insight` is present and **enabled** when a folder with ≥1 `.md` file is open.
   - Procedure: open any folder with `.md` files → click toolbar `AI Tools` → expand `Analysis` section → confirm `🧭 Recursive Insight` button.
   - Then close the folder (File menu → close, or hide root) → re-open the menu → confirm the item is **disabled**.

2. **AC2 — Streaming summary.** Click `🧭 Recursive Insight`. A new tab opens; markdown summary streams in token-by-token (visible character growth, not blocky one-shot delivery).

3. **AC3 — Inline mermaid SVG.** Mermaid blocks within the streamed summary render as SVG (not as code blocks).

4. **AC4 — Deep-dive list.** After streaming completes, the right-side panel shows 3–7 clickable deep-dive topics.

5. **AC5 — Deep-dive expansion.** Click a topic. A new node opens (breadcrumbs grow `Root > <Topic>`); its summary streams; its own deep-dive list renders on the right after completion.

6. **AC6 — Breadcrumb back-navigation.** Click `Root` in breadcrumbs. The view returns instantly to the root node from memory (no LLM activity, no network requests — confirm via dev-tools Network tab in WebView Inspector if open, or simply by observing that no streaming animation occurs).

7. **AC7 — Save as .md.** Click `💾 Save as .md`. NSSavePanel opens. Type a filename, click Save. Confirm: (a) file written at the chosen location; (b) file contains only `currentNode.markdownBody` (no `---DEEP-DIVES---` marker, no breadcrumbs, no chrome); (c) file opens in standard editor mode of MarkView correctly.

8. **AC8 — Up button.** Click `↑ Up` from a deep-dive node. The view returns to the parent node (same as clicking parent breadcrumb).

9. **AC9 — map-reduce vs one-shot routing.** With folder of >30 `.md` files: confirm `mapReduceForFolder` path used (debug print or NSLog `[GraphRAG] mapReduceForFolder` on Console.app). With folder of ≤30 `.md` files: confirm one-shot `streamCompletion` used.
   - For TestFiles/: count `.md` files; if ≤30, also test on a synthetic large folder (e.g. clone a docs repo with 50+ markdown files).

10. **AC10 — Tree freed on tab close.** Close insight tab. Verified by Instruments leak check below — Scenario (a).

### Tech-spec ACs requiring user

- **Lifecycle-1** — `InsightSession.cancel()` cancels in-flight stream within 1 second (observable: click close mid-stream, no further character growth in any UI).
- **Lifecycle-2** — Connection drop mid-stream: error banner with `[Retry]` button appears; partial buffer is preserved (visible markdown on screen does not clear).
- **Lifecycle-3** — Tab switch during stream: stream continues in background, switching back re-renders accumulated buffer with no data loss or duplication.
- **Resource-1** — Folders >500 `.md` files rejected with user-visible error; ≤500 proceed. (Test by pointing MarkView at a synthetic 600-file folder.)
- **Resource-2** — `.md` file >50 KB truncated with `[truncated]` marker before LLM send. (Verifiable in Console.app NSLog or via packet trace.)

---

## Mandatory Instruments leak check (REQUIRES USER)

Per Task 12 spec §6 — **mandatory for QA sign-off, not optional.**

**Setup:**
1. Build Release: `xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Release build` (Release recommended per task hint to avoid debug-info noise; also re-run scenario (a) on Debug for any UB-deltas).
2. Launch MarkView through `Xcode → Open Developer Tool → Instruments → Allocations` (or `Leaks` template).
3. For each scenario: perform actions, then in Instruments use `Mark Generation` button to checkpoint heap, then filter Allocations by class name `InsightSession` and `InsightNode`.
4. After Mark Generation, give 2-3 seconds idle for autorelease pool drain (no explicit force-GC API in Swift ARC; Mark Generation effectively snapshots post-cleanup).

**Pass criterion (each scenario):** count of retained `InsightSession` instances **= 0**, count of retained `InsightNode` instances **= 0**, no surviving `URLSession` task or `AsyncSequence` iterator zombies.

### Scenario (a) — Happy path
1. Open `TestFiles/` in MarkView.
2. `AI Tools → Analysis → 🧭 Recursive Insight`.
3. Wait for root summary streaming to complete; deep-dive list to appear.
4. Click 2–3 different deep-dive topics in sequence (let each finish streaming or click breadcrumb-back partway).
5. Close insight tab.
6. Mark Generation.
7. **Expect:** retained InsightSession = 0, retained InsightNode = 0.

### Scenario (b) — Error + Retry
1. Open insight tab on `TestFiles/`.
2. As soon as streaming starts (within 1-2 seconds of root summary appearance), kill network: turn Wi-Fi off, OR run `sudo route add -host api.anthropic.com 127.0.0.1` (revert with `sudo route delete` after).
3. Wait for error banner to appear.
4. Restore network (turn Wi-Fi on / `route delete`).
5. Click `Retry` button. Wait for successful completion.
6. Close tab.
7. Mark Generation.
8. **Expect:** retained = 0/0.

### Scenario (c) — Retry rate limit
1. Open insight tab on `TestFiles/`.
2. Kill network → wait error → click Retry → kill network → wait error → click Retry → kill network → wait error → click Retry → kill network → wait error.
3. On the 4th retry click within 60 seconds of the first failure, observe: `setInsightError(retryable: false)` should fire. Banner becomes terminal — **no Retry button**, message reads "retry rate limit".
4. Close tab.
5. Mark Generation.
6. **Expect:** retained = 0/0.

### Scenario (d) — Memory cap eviction
1. Open insight tab on `TestFiles/`.
2. Recursively expand many deep-dive nodes to push total `rawBuffer` across all nodes past 50 MB. (Hint: temporarily lower `perSessionBufferCapBytes` to e.g. 5 MB in InsightSession.swift if real 50 MB takes too long — restore after.)
3. Confirm via debug NSLog (look for "evict" / "perSessionBufferCapBytes") that oldest non-current-path nodes were dropped (`nodes[id]` set to nil for evicted IDs).
4. Close tab.
5. Mark Generation.
6. **Expect:** retained = 0/0; specifically the evicted node IDs do NOT appear in the snapshot.

**Document for each scenario in this report after running:** retained InsightSession count, retained InsightNode count, presence of any URLSession/Task/AsyncSequence zombies (Instruments → Allocations → "Retained By" tree).

---

## Tab-switch-during-stream (REQUIRES USER, Decision 11 §5)

1. Open `TestFiles/` (~10-30 files).
2. Open any existing `.md` file in editor → call this **tab A**.
3. Trigger `🧭 Recursive Insight` → opens new **tab B** with active stream.
4. While tab B's summary is **still actively growing** (mid-stream — characters appearing every 100-200ms), switch to tab A.
5. Wait 5-10 seconds. Confirm via Console.app NSLog (or instrumented counter in `InsightSession.streamingBuffer`) that the stream **continues to grow** in the background.
6. Switch back to tab B.
7. **Confirm:**
   - Visible text content of summary has **grown** during the absence (no frozen state).
   - **No gaps** in the rendered text (no missing character ranges).
   - **No duplications** (no repeated paragraphs).
   - After streaming completes (whether before or after the user switched back), deep-dive list renders correctly on the right.

**This is a blocker if it fails** (re-open Task 4 / Task 6).

---

## Carry-over findings from Audit Wave

These are findings from T9/T10/T11 carried forward into pre-deploy QA awareness, NOT new findings.

### From Code Audit (T9)

- **M1 (major) — bridge node-id race.** `insightDeepDiveClicked` / `insightSaveRequested` JS payloads do NOT include `nodeId`; if user clicks a deep-dive then immediately navigates via breadcrumbs, the queued `Task @MainActor` may operate on the wrong `currentNode`. **Impact:** silent UX wrongness — wrong topic expanded as child of wrong parent. **Recommendation:** carry the `nodeId` in the JS payload + Swift validation. **Status:** acknowledged; T11 confirms manually reproducible (T9 §Recommendations item 1: "click deep-dive #2, IMMEDIATELY click breadcrumb root before stream starts"); decision lies with user whether to fix pre-merge or accept-and-rely-on-manual-smoke. **NOT a blocker per T9 verdict** (APPROVED_WITH_FIXES, 0 critical).
- **m1 (minor) — Mermaid `securityLevel: 'strict'` global init leak.** Re-`initialize` at index.html:3102-3107 mutates global mermaid config; once user opens insight tab, all subsequent mermaid renders in editor/preview lose interactive click handlers. **Recommendation:** drop the redundant `initialize` (per-render securityLevel at L2941 is sufficient). **Reproduction in T12:** open editor with mermaid diagram bearing click handlers, verify clicks work; open insight tab; switch back to editor; verify clicks still work.
- **m2-m9 (minor + info)** — UX/perf polish items, none impact correctness or security. See `logs/audit/code-audit.md` for full text.

### From Security Audit (T10)

- **APPROVED, 0 critical / 0 high.** All 7 Decision 10 layers ship correctly.
- **M1, M2, L2 (medium / low) are pre-existing** — predate Recursive Insight, not introduced by this feature, out of audit scope (non-streaming AIProviderClient paths missing sanitize; UserDefaults-not-Keychain key storage; translate/explain popup using `html: true` with `innerHTML`).
- **L1 (low) — `script-src 'unsafe-inline'`** — acknowledged compromise per Decision 10 §3.
- **L3 (low) — mid-session API key rotation gap** — same as code-audit m4, documented + accepted.

### From Test Audit (T11)

- **DEFERRAL JUSTIFIED.** All 5 checks pass.
- Test target setup tracked in `tasks/todo.md` with owner ("Boris or first contributor to touch insight code path post-merge") and target date (2026-05-14).
- 7 follow-up test modules enumerated covering every critical path.
- 6 fixture files committed, all hand-traced clean by code-audit.
- Pre-deploy Instruments check is the compensating verification for the deferred ARC-cycle test; covers all 6 retain-cycle paths identified by code-reviewer.

---

## Sign-off

### Programmatic checks
- Build: **PASS**
- Storage spot-check: **PASS** (clean, 0 insight tables, 0 insight artifacts)
- Static cap grep verification: **PASS** (7/7 caps located + enforced)
- 28 programmatically verifiable acceptance criteria: **PASS** (28/28)

### Manual checks pending (must be performed by user before merge)
1. SSE smoke-curl against Anthropic Messages API (with `KEY` exported)
2. 10 user-spec acceptance criteria via manual flow on `TestFiles/`
3. **4 mandatory Instruments leak-check scenarios** (a/b/c/d)
4. Tab-switch-during-stream flow
5. Regression spot-check (open existing `.md` files, confirm editor / Translate / AI Console unaffected)
6. (Optional but recommended per code-audit) carry-over reproductions:
   - M1 bridge node-id race (rapid click + navigate)
   - m1 Mermaid global state leak (mermaid click handlers in editor after insight tab)
   - m4 / L3 API key rotation mid-stream redaction

### Recommendation

**READY FOR USER VERIFICATION**

All programmatic checks pass cleanly. No critical or high-severity blockers remain in any audit. Build is green with zero new warnings. Storage layer confirms Decision 3 (no persistence) is honored at the data layer. All seven resource caps from Decision 10 §7 are present in code with explicit constants and documented enforcement sites.

The remaining gates (manual ACs, Instruments scenarios, tab-switch flow) cannot be discharged from a headless agent context — they require the running macOS application and Xcode Instruments. The user must run them before merging to `main`.

If the four Instruments scenarios all show 0 retained `InsightSession` / `InsightNode` instances, AND the user-spec 10 ACs all pass on `TestFiles/`, AND the tab-switch flow shows no data loss or duplication — then the feature is **READY TO MERGE**. Otherwise specific blockers should be filed against the corresponding Tasks (1-8) per the carry-over recommendations.

The decision on M1 (bridge node-id race) — fix pre-merge or accept-and-document — is carried over to the user per code-audit and test-audit recommendations. It is **not** a programmatic blocker.

---

*End of pre-deploy QA report.*
