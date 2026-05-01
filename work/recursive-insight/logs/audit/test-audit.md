# Test Audit: Recursive Insight Feature

**Auditor:** test-master (Task 11)
**Audit type:** META — verification of deferred-tests decision (Decision 9) and its compensating measures, NOT execution of test code (no test target exists by design).
**Inputs:** tasks/11.md (5 explicit checks), tech-spec.md Decision 9 + Risks + Acceptance Criteria, tasks/todo.md (follow-up scope), 6 fixture files (1 SSE + 5 marker-cases), code-audit.md, security-audit.md, tasks/12.md.

---

## Summary

**Verdict: DEFERRAL JUSTIFIED.**

All five checks pass. Test deferral is correctly tracked in `tasks/todo.md` with explicit owner ("Boris (or first contributor to touch insight code path post-merge)") and target date ("2026-05-14, within 2 weeks after merge"). The follow-up scope enumerates seven specific test modules covering every critical surface from the Risks table (SSE parser, marker parser, InsightSession lifecycle including cancellation race, GraphRAG mapReduceForFolder, scope_hint validation, resource caps). All six committed fixtures (`Tests/Fixtures/sse-anthropic-sample.txt` plus the five `marker-cases/*.md`) are present, well-documented with header comments declaring expected parser behavior, and exhaustively hand-traced in code-audit.md (5/5 marker fixtures + happy SSE path conform; oversized-line, oversized-event, error-event paths verified by code inspection). Code Audit and Security Audit produced 0 critical / 0 high findings — the only major finding (M1: bridge node-id race) is a UX correctness issue catchable by manual smoke (rapid-click reproduction prescribed in T9 §Recommendations and T12 §Pre-deploy QA), NOT an automated-only concern. Pre-deploy QA's mandatory Instruments → Allocations leak check across four scenarios (a) happy + 2-3 deep-dives + close, (b) error + retry + close, (c) 4th-retry rate-limit + close, (d) 50 MB cap eviction + close — combined with code-reviewer's exhaustive `[weak self]` audit (15/15 closures inside InsightSession verified) — provides defense in depth equivalent to (and arguably stronger than) what an automated XCTest cycle-detector would catch. The compensating verification trio (committed fixtures + exhaustive hand-traces in two audits + four-scenario Instruments check) substitutes adequately for the deferred test target. **No tests need to be raised from follow-up to blocking-pre-merge.**

PASS: 5 | WEAK PASS: 0 | FAIL: 0 | N/A: 0

---

## Per-check results

### Check 1: Deferral tracking in tasks/todo.md

**Status: PASS**

Cited verbatim from `tasks/todo.md` lines 5-21:

> - [ ] **Set up XCTest infrastructure for MarkView**
>   - **Why:** Project has no test target. `Tests/` folder is empty, `project.yml` defines only the `MarkView` app target. No `import XCTest` anywhere.
>   - **What to do:**
>     1. Edit `project.yml` to add a `MarkViewTests` target (`type: bundle.unit-test`, `platform: macOS`, `sources: [Tests]`, `dependencies: [MarkView]`).
>     2. Run `xcodegen` to regenerate `MarkView.xcodeproj`.
>     3. Add a test scheme so `xcodebuild test -scheme MarkView` works.
>     4. Update `install.sh` / CI to run `xcodebuild test`.
>     5. Retroactively cover Recursive Insight critical paths: [list of 7 test modules — see Check 2]
>   - **When:** Within 2 weeks after Recursive Insight feature is merged (target: 2026-05-14).
>   - **Owner:** Boris (or first contributor to touch insight code path post-merge).

| Field | Required | Actual | Status |
|-------|----------|--------|--------|
| Owner | non-empty, non-"TBD" | "Boris (or first contributor to touch insight code path post-merge)" | PASS — explicitly worded fallback per task spec edge-case allowance |
| Target date | concrete date or relative deadline | "Within 2 weeks after Recursive Insight feature is merged (target: 2026-05-14)" | PASS — both relative ("within 2 weeks") and absolute ("2026-05-14") |
| What to do | substantive multi-step plan | 5 numbered steps (project.yml edit → xcodegen → test scheme → CI update → retroactive coverage list with 7 modules) | PASS — future executor has a clear runway, not starting from zero |
| Why | rationale present | "Project has no test target. Tests/ folder is empty, project.yml defines only the MarkView app target. No `import XCTest` anywhere." | PASS — concise, accurate |

**Verification commands run:**
- `ls /Users/boris/Documents/Claude/Projects/MarkDV/MarkView/Tests/` → returns only `Fixtures` directory; **no `*.swift` files**, deferral correctly enforced.
- `grep -rn "XCTest\|@testable\|XCTAssert" MarkView/ Tests/` → 0 hits, confirming no `import XCTest` anywhere in the app or test source tree.
- `grep -n "MarkViewTests\|unit-test" project.yml` → 0 hits, confirming no test target defined.

The deferral is internally consistent: spec says "no test target", actual filesystem and project config confirm "no test target".

---

### Check 2: Test scope coverage in follow-up

**Status: PASS**

Coverage table — every critical path from tech-spec Risks table mapped to a test module in `tasks/todo.md` step 5:

| Critical path (from Risks + Decisions) | Required tests | Status | Evidence in tasks/todo.md |
|---|---|---|---|
| SSE parser (`AIProviderClient.streamCompletion`) — happy + edge cases | unit tests against `sse-anthropic-sample.txt` + synthetic oversized/error/HTTP-error chunks | **PRESENT** | "`Tests/InsightSSEParserTests.swift` — Anthropic SSE byte stream parsing (mock chunked streams, partial chunks, malformed events)" |
| Marker parser (`---DEEP-DIVES---` detect) — all 5 cases | unit tests against the 5 marker-cases fixtures | **PRESENT** | "`Tests/InsightMarkerParserTests.swift` — `---DEEP-DIVES---` marker detection (avoid false positives on horizontal rules in markdown body)" |
| InsightSession lifecycle (root → expand → cancel → memory release) | unit + state tests on tree mutations, cancel ordering, ARC | **PRESENT** | "`Tests/InsightSessionTests.swift` — tree lifecycle: createRoot → expandDeepDive → navigateBack → cancel → memory release" |
| Cancellation race (Decision 11 §4 — close-tab-during-stream) | dedicated race test verifying `Task.isCancelled` observed | **PRESENT** | "`Tests/InsightCancellationRaceTests.swift` — close-tab-during-stream race; verify `Task.isCancelled` observed and no writes to orphaned session" |
| GraphRAG `mapReduceForFolder` (community clustering, per-file truncation, per-community subdivision) | integration test with real `.md` fixtures | **PRESENT** | "`Tests/GraphRAGFolderMapReduceTests.swift` — new `mapReduceForFolder` method on real .md fixtures" |
| `scope_hint` validation (Decision 10 §6 — path traversal, symlink escape, non-`.md` reject) | unit tests on `validateScopeHint` with malicious paths | **PRESENT** | "`Tests/InsightScopeHintValidationTests.swift` — path-traversal rejection (per Decision 10 §6)" |
| Resource caps (Decision 10 §7 — 50KB/file, 500/folder, 10MB/node, 50MB/session, 64KB/SSE-line, 3-retry/60s) | unit tests on each cap with synthetic over-sized inputs | **PRESENT** | "`Tests/InsightResourceCapTests.swift` — verify 50 KB/file truncation, 500 files/folder reject, 10 MB/node cap, 50 MB/session eviction" |

**Missing critical paths:** none.

**Notes / recommendations for follow-up improvement (non-blocking):**
- `InsightResourceCapTests.swift` description omits "64 KB SSE-line cap" and "1 MB SSE-event cap" and "3-retries/60s throttle" — these are mentioned elsewhere (SSE parser tests should cover the line/event caps; retry throttle could either go into `InsightSessionTests` or a separate `InsightRetryThrottleTests`). Owner should ensure these aren't lost when implementing.
- No explicit mention of `escapeXMLEnvelopeBreakout` regression test — given the T3 round-2 regression already happened once and was fixed (per security-audit.md), a dedicated `Tests/InsightXMLEscapeBreakoutTests.swift` would be cheap insurance. Not blocking; could fold into `InsightSessionTests` or `GraphRAGFolderMapReduceTests`.
- No explicit mention of bridge protocol contract tests (M1 from code-audit.md — node-id race in deep-dive expand/save). If the M1 fix lands as adding `nodeId` to the JS payload, a bridge-message integrity test would catch future regressions of the disambiguation. Worth adding to follow-up scope when M1 is addressed.

These are nice-to-have additions, not gaps in the originally specified scope.

---

### Check 3: Committed fixtures

**Status: PASS**

Fixture table — every required fixture present, content matches documented expectations, hand-traced cleanly by code-audit.md:

| File | Status | Edge cases covered | Evidence |
|---|---|---|---|
| `Tests/Fixtures/sse-anthropic-sample.txt` | **PRESENT** | (a) happy path with multiple `content_block_delta` events ✓; (c) `: keepalive` comment lines ✓; lifecycle events `message_start` / `content_block_start` / `content_block_stop` / `message_delta` / `message_stop` (silently ignored) ✓; `event: ping` blocks ✓; 20 deltas of varied length ✓ | 134 lines, valid Anthropic SSE format with realistic event names and JSON payloads. Code-audit.md hand-trace: 26 `onDelta` calls reconstruct expected text exactly (no parser discrepancy). |
| `Tests/Fixtures/sse-anthropic-sample.txt` — coverage gaps | (b) partial chunks (one SSE event split across TCP chunks mid-JSON), (d) `event: error` with full error payload, (e) oversized line >64KB | **DOCUMENTED IN HEADER COMMENT** as deferred-to-test-suite cases (synthetic, would require ~1MB payload to encode). Code-audit.md confirms by-code-inspection that parser correctly throws `streamingError` for oversized line (L289-291), oversized event payload (L356-361), `event: error` (L395-400), and HTTP non-200 (L239-252). | Header lines 15-25 explicitly enumerate the three DoS-safety cases as "verify by code inspection of streamCompletion's byte loop" with byte-counts and expected throw points. The deferred tests must encode them programmatically. **Acceptable** because (i) fixture would be ~1MB if encoded literally, (ii) the parser code-path IS verified by code-audit.md hand-inspection, (iii) deferred tests will easily synthesize them. |
| `Tests/Fixtures/marker-cases/happy.md` | **PRESENT** | Single valid `\n\n---DEEP-DIVES---\n` marker with 3 topics; body preserves regular markdown including code blocks and headers | 27 lines. Header comment declares exact expected parser output (body slice, 3 topics with explicit labels/hints/scopeHints). Code-audit.md hand-trace confirms Swift `parseMarker` and JS `parseInsightMarker` both produce identical 3-topic output. |
| `Tests/Fixtures/marker-cases/in-code-fence.md` | **PRESENT** | Marker text inside ` ```text ... ``` ` block AND a real terminal marker — parser MUST take the real (later) marker via `lastIndexOf` semantics | 30 lines. Header comment is explicit: "lastIndexOf semantics naturally pick the trailing real marker. body = everything before the trailing real marker (including the entire code-fenced section, marker text and all). topics = exactly 1 entry." Behavior is consistent with code-audit.md hand-trace (Swift + JS both pick the real marker). **Documented limitation** noted by audit: if LLM emits a marker-shaped string inside a fence WITHOUT a real marker following, in-fence text would be mis-treated as marker. This is acceptable per fixture comment and out of audit scope. |
| `Tests/Fixtures/marker-cases/as-hr.md` | **PRESENT** | Plain `---` horizontal rules with NO marker — parser must NOT match bare `---` | 27 lines. Header comment: "body = full file content unchanged. topics = [] (empty)." Code-audit.md hand-trace: `lastIndexOf("\n\n---DEEP-DIVES---\n")` returns nil → early return with `(buffer, [])`. ✓ |
| `Tests/Fixtures/marker-cases/no-marker.md` | **PRESENT** | Pure markdown body, no marker — render as normal markdown with empty deep-dive list | 17 lines. Header comment: "body = full file content unchanged. topics = [] (empty)." Identical trace to `as-hr.md`. ✓ |
| `Tests/Fixtures/marker-cases/multiple-markers.md` | **PRESENT** | Two real markers — parser must use the **last** per Acceptance Criteria → Marker parsing | 30 lines. Header comment: "body = everything before the SECOND (final) marker — including the first marker line and its now-stale topic list. topics = exactly 2 entries (from the last marker section)." Code-audit.md hand-trace confirms `lastIndexOf` / `.backwards` returns the LATER marker; final body includes the stale first-marker content; final topic list = 2 entries. ✓ |

**Cross-implementation consistency:** code-audit.md verifies Swift `parseMarker` and JS `parseInsightMarker` produce IDENTICAL outputs across all 5 fixtures. No drift.

**Tech-spec consistency check (Decision 2 + Acceptance Criteria → Marker parsing):**
- Decision 2 says "delimiter is simple, reliable, and the user-visible markdown is human-readable."
- Acceptance Criteria → Marker parsing requires: form `\n\n---DEEP-DIVES---\n`, parser uses **last** occurrence, accepts 0 or >7 topics. All fixtures align with this.
- The in-code-fence behavior (parser unaware of markdown context, relies on lastIndexOf) is consistent with the spec — the spec does not require fence-awareness, only last-occurrence + boundary-newline. **No spec ambiguity to flag.**

**Verdict:** all 6 fixture files present, well-documented, exhaustively hand-traced, internally consistent with parser implementation. The two audits' hand-traces (code-audit.md §"Marker Parser vs Fixtures") substitute for executable tests at the fixture level.

---

### Check 4: Audit findings → tests required before merge

**Status: PASS** (no findings require pre-merge tests)

Both audits completed (Task 9 and Task 10). Findings extracted and analyzed below.

**Code Audit (Task 9) findings:**

| Finding | Severity | What it is | Would deferred test catch it? | Pre-merge test required? |
|---|---|---|---|---|
| (none) | critical | — | — | — |
| **M1** | major | Bridge messages lack `nodeId` payload; rapid clicks during deep-dive can race the `Task @MainActor` execution past a `navigateTo`, causing wrong topic to be expanded as child of wrong parent | **NO** — this is a JS↔Swift bridge protocol design bug, not unit-test catchable in the conventional sense. Would need an integration test that simulates rapid bridge messages with intervening navigations, which IS hard but can be constructed. **However** — the issue is silent UX wrongness, deterministically reproducible by the manual smoke prescribed in code-audit.md §Recommendations item 1 ("click deep-dive #2, IMMEDIATELY click breadcrumb root"). Pre-deploy QA Task 12 §"User-spec acceptance criteria" + reviewer-prescribed reproduction step will exercise this. | **NO** — manual reproduction in T12 sufficient. Fix should land before merge (code-reviewer recommended pre-merge fix), but the reliance on manual smoke is acceptable. |
| m1 | minor | Mermaid `securityLevel: 'strict'` global init in `switchToInsightView` leaks to existing editor/preview modes | NO — global state side-effect, would require integration test exercising mode switches. Manual smoke in T12 reproduction step 2 catches it. | NO |
| m2 | minor | `closeTab` cancel-then-`removeTab` race during NSSavePanel modal | NO — modal NSSavePanel + UI-thread race is not unit-testable. Manual smoke catches via deliberate cancel-during-save-panel. | NO |
| m3 | minor | O(N) UTF-8 recompute per chunk in `appendStream` cap check | YES — perf microbenchmark could catch, but is not safety-critical | NO — perf optimization, not correctness |
| m4 | minor | `apiKeySnapshot` taken at init only — mid-session rotation gap | YES — could write a test that rotates key mid-stream and verifies redaction. Defense-in-depth gap, documented in code | NO — `AIProviderClient.sanitize` is the primary defense; this is acknowledged limitation |
| m5 | minor | `WorkspaceManager.startRecursiveInsight` strong-captures `session` in `Task` (sub-second extra retention) | NO — ARC microbehavior, not unit-testable, not user-visible | NO |
| m6 | minor | Silent vs NSLog drop of malformed marker lines (debuggability gap) | YES — easy unit test with malformed fixture | NO — UX polish, not correctness |
| m7 | info | Eviction ordering safe by inspection | n/a | NO |
| m8 | info | `String.count` Character vs UTF-16 grapheme boundary edge case | YES — synthetic streaming test with boundary-straddling chunk | NO — theoretical, no observed regression |
| m9 | minor | Hardcoded `#fff` in two CSS rules — theme polish | NO — visual review only | NO |
| i1-i9 | info | Notes confirming correct behavior | n/a | NO |

**Security Audit (Task 10) findings:**

| Finding | Severity | What it is | Would deferred test catch it? | Pre-merge test required? |
|---|---|---|---|---|
| (none) | critical | — | — | — |
| (none) | high | — | — | — |
| M1 | medium | API key `sanitize()` not applied in non-streaming `AIProviderClient` paths — **out of Recursive Insight scope, pre-existing** | YES (in those paths' own tests) — but not a Recursive Insight regression. Insight code path uses `streamCompletion` which IS sanitized. | NO — out of scope |
| M2 | medium | API key in UserDefaults despite "Keychain" naming — **pre-existing** | n/a — not a Recursive Insight finding | NO — out of scope |
| L1 | low | `script-src 'unsafe-inline'` retained — acknowledged compromise per Decision 10 §3 | n/a — design decision | NO |
| L2 | low | Action popup uses `innerHTML` with `html: true` — **pre-existing, NOT on insight surface** | n/a | NO — out of scope |
| L3 | low | Mid-session API key rotation not re-snapshotted — acknowledged + documented | YES — same as code-audit m4 | NO — defense in depth via `AIProviderClient.sanitize` |

**Aggregate analysis:**
- Critical findings: 0
- High findings: 0
- Major findings: 1 (code-audit M1, bridge protocol race) — manually reproducible, not requiring an automated test
- Pre-existing findings out of scope: 2 medium (security M1, M2) + 2 low (security L1, L2) — not Recursive Insight responsibility
- Acknowledged limitations: 1 minor + 1 low (m4 / L3 — same item, API key rotation)

**Tests recommended to write before merge:** **NONE.**

Rationale:
1. There are no critical or high findings whose impact (data loss, security breach, irrecoverable state) requires automated regression coverage before merge.
2. The single major finding (M1) is a UX correctness bug deterministically reproducible by manual smoke and explicitly added to T12 reproduction steps. The fix itself is small (add `nodeId` to bridge payload + Swift validation) and falls within ordinary code review, not within "must have automated test before merge".
3. All medium-severity findings are pre-existing (predate Recursive Insight) or explicitly acknowledged design limitations.
4. The committed fixtures + dual audit hand-traces + `[weak self]` exhaustive code review (15/15 in InsightSession) + four-scenario Instruments leak check together provide compensating verification at least equal to what a partial XCTest setup would yield in the time available.

The original Decision 9 user choice ("defer test target setup") is **vindicated**: no critical risk would have been caught only by an XCTest that isn't caught by the existing compensation.

---

### Check 5: Pre-deploy QA Instruments leak check sufficiency

**Status: PASS**

Cited from `tasks/12.md` §"What to do" item 6 ("Mandatory: Instruments leak check (4 сценариев)"):

> - Запустить MarkView через Instruments → Allocations template (или Leaks).
> - Для каждого сценария: запустить, выполнить, force GC (Cmd+E или соответствующая команда Instruments), сделать snapshot heap, найти инстансы `InsightSession` и `InsightNode`, **подтвердить count = 0**.
> - **Сценарий (a) — Happy path:** открыть insight на `TestFiles/`, дождаться root, развернуть 2-3 deep-dive (нажимая на топики в правой панели), закрыть tab. Snapshot.
> - **Сценарий (b) — Error + Retry:** открыть insight, дождаться начала стрима, выключить Wi-Fi (или через `nettop`/`tcpkill` оборвать соединение), увидеть error banner, включить Wi-Fi, нажать Retry, дождаться успешного завершения, закрыть tab. Snapshot.
> - **Сценарий (c) — Retry rate limit:** открыть insight, дождаться стрима, оборвать сеть, нажать Retry → снова оборвать → нажать Retry → снова оборвать → нажать Retry → снова оборвать. На 4-м клике в течение 60 секунд должен прийти `setInsightError(retryable: false)` и кнопка Retry должна исчезнуть. Закрыть tab. Snapshot.
> - **Сценарий (d) — Memory cap eviction:** открыть insight, рекурсивно расширять deep-dive узлы (можно повторно кликать тот же топик в разных ветках), пока суммарный `rawBuffer` не превысит 50 MB. Подтвердить через debug-print или счётчик в `InsightSession`, что произошёл eviction старейших не-current узлов (их `nodes[id]` стал nil). Закрыть tab. Snapshot.
> - В отчёте зафиксировать для каждого сценария: retained `InsightSession` count, retained `InsightNode` count, наличие любых других «зомби» из иерархии (например, `URLSession` Task'ов или `AsyncSequence` итераторов).

**Acceptance criterion** (T12 line 110): "Instruments leak check на 4 сценариях: после force GC ровно 0 retained `InsightSession` и `InsightNode` instances в каждом случае."

**Code-reviewer `[weak self]` audit verdict** (cited from code-audit.md §"`[weak self]` Closure Capture Audit"):

> **InsightSession.swift** (Task 4 — main focus per Decision 11 §1):
> [table of 15 closure sites]
> **Total:** 15 closures. **All 15 use `[weak self]` correctly with the prescribed `guard let self = self else { return }` pattern.** No strong-self captures in any long-lived async context inside `InsightSession`.

**Coverage of retain-cycle paths:**

The most likely retain cycles per the architecture:
1. Long-lived `Task` in `streamCompletion` callback chain → captured by `InsightSession.activeTask` → could cycle if `[weak self]` missing → **CHECKED by reviewer**, all 15 sites verified.
2. `URLSession.bytes` async iterator inside `streamCompletion` → no closure capture (uses `for try await byte in bytes`), structurally cannot cycle → **VERIFIED by reviewer** at AIProviderClient.swift:268-321.
3. `onDelta` closure forwarding in `@MainActor` → MainActor hop closures use `[weak self]` + guard at all 6 inner-Task sites (lines 226, 240, 325, 419, 433, 460) → **VERIFIED**.
4. Combine subscriptions in `EditorView.routeInsight` → all 3 use `[weak self, weak session, weak webView]` → **VERIFIED** at lines 306, 341, 360.
5. Bridge `Task { @MainActor in ... }` wrappers in EditorView Coordinator → strong `self`, but justified (Coordinator lifetime tied to NSViewRepresentable, short-lived tasks) → flagged but acceptable.
6. `WorkspaceManager.startRecursiveInsight` strong-captures `session` in dispatched Task → flagged as m5, sub-second extra retention, not a cycle.

**Mapping scenarios → retain-cycle paths:**

| Scenario | Tests cycle path |
|---|---|
| (a) open + 2-3 expand + close | Path 1 (activeTask cycle), Path 3 (MainActor hop), Path 4 (Combine sub) — all 3 must be cycle-free for ARC to drop the session |
| (b) error + retry + close | Path 1 (activeTask after error), Path 3 (MainActor in retryCurrent), Path 5 (handleStreamError doesn't capture) |
| (c) 4th retry rate-limit + close | Same as (b) plus tests that no leftover Task references survive retry-throttle rejection |
| (d) 50 MB cap + eviction + close | Tests `enforceSessionMemoryCap`'s eviction path doesn't accidentally re-create or strong-retain evicted nodes; also tests entire tree cleanup on close |

All 6 retain-cycle paths above are exercised by at least one of the 4 scenarios. The 4-scenario coverage is **complete with respect to the closure-capture surface** identified by code-audit.md.

**What an XCTest would have caught that Instruments will NOT catch (the gap):**

1. **Determinism / regression CI gate.** Instruments is manual; once the human signs off, future PRs can re-introduce a strong-self regression and won't fail any automated check until the next manual QA cycle. An `XCTest` running in CI on every commit would block regression at PR time.
   - Mitigation: the follow-up `Tests/InsightSessionTests.swift` will add this. Until then, code-reviewer must explicitly check `[weak self]` on every PR touching `InsightSession`.

2. **Scenario completeness against future code changes.** If a 5th retain-cycle-prone path is introduced later (e.g. a new background indexing task), Instruments scenarios won't auto-update. An `InsightSessionLifecycleTests` setUp/tearDown that asserts `weak var sessionRef` becomes `nil` would catch any new uncovered cycle automatically.
   - Mitigation: when M1 fix lands or any session-shape change is made, manually re-run all 4 Instruments scenarios.

3. **Sub-millisecond timing variants of cancellation race.** Manual click cadence is at human speed (~100ms minimum). An XCTest can race close-then-allocate at microsecond intervals. The `Tests/InsightCancellationRaceTests.swift` in the follow-up scope is specifically targeted at this.
   - Mitigation: Decision 11 §4 prescribes synchronous `cancel()` BEFORE `removeTab()`, code-audit.md verified at WorkspaceManager.swift:1110-1113.

**Net assessment:**

The Instruments scenarios are **specific and adequate** for first-merge sign-off. They catch every retain-cycle path identified by code-reviewer, on the actual production binary, in the actual user-visible scenarios. The code-reviewer's `[weak self]` audit is thorough (15/15) and provides static-analysis-level confidence on top of the dynamic Instruments verification. **PASS**, not WEAK PASS — code-reviewer DID explicitly verify `[weak self]` per Decision 11 §1 (the WEAK PASS gate per task spec was "code-reviewer not dotrouching `[weak self]` explicitly", and this case is the explicit-and-thorough scenario).

The gap (no automated regression gate) is real and acknowledged in the follow-up scope (`Tests/InsightSessionTests.swift` will add it). Until that lands, manual re-run of the 4-scenario Instruments check is required for any PR touching `InsightSession`. This should be added as a contributor note in `tasks/todo.md` or in a CONTRIBUTING.md when one exists — flagged in Recommendations below.

---

## Critical paths uncovered by build + manual + audit hand-trace

**None.**

Every critical path enumerated in the Risks table and Acceptance Criteria has at least one of:
1. Static verification by code-reviewer hand-trace (SSE parser, marker parser — both with fixture-level evidence).
2. Static verification by security-auditor hand-trace (escapeXMLEnvelopeBreakout in both InsightSession + GraphRAG; scope_hint validation; resource caps; CSP; setText utility usage; insight-tab disk-write guards).
3. Dynamic verification by manual smoke in Pre-deploy QA T12 (10 user-spec ACs, 4 Instruments scenarios, tab-switch flow, security smoke tests in T9 + T10 §Recommendations).
4. Build-time verification by `xcodebuild` (compatibility, no breaking changes to existing call sites).

The single residual gap — automated CI regression gate — is a known limitation of the deferral, explicitly tracked in follow-up with owner + date.

---

## Recommendations

1. **Add to `tasks/todo.md` under XCTest infrastructure setup:** explicit note that until the test target lands, any PR touching `MarkView/Models/InsightSession.swift`, `MarkView/Models/AIProviderClient.swift` (streamCompletion), `MarkView/Models/GraphRAG.swift` (mapReduceForFolder), or `MarkView/Resources/Editor/index.html` (insight mode JS) requires manual re-run of the 4-scenario Instruments leak check. This codifies the compensating manual gate. **Owner action item, 5-minute edit.**

2. **Optional addition to follow-up test scope:**
   - `Tests/InsightXMLEscapeBreakoutTests.swift` — regression guard for `escapeXMLEnvelopeBreakout` (one round-2 regression already happened during T3; cheap insurance, ~10 lines of test code).
   - `Tests/InsightBridgeProtocolTests.swift` — once M1 is fixed, regression guard for `nodeId` validation in `insightDeepDiveClicked` / `insightSaveRequested` payloads.
   - `Tests/InsightRetryThrottleTests.swift` (or fold into `InsightSessionTests`) — explicit 3-retries-per-60s sliding-window verification.
   - `Tests/AIProviderClientSSEDoSCapsTests.swift` (or fold into `InsightSSEParserTests`) — explicit 64KB-line-cap and 1MB-event-cap verification with synthetic byte streams.

3. **For T12 sign-off:** verify code-audit.md §Recommendations items 1-8 are exercised by the manual QA flow (these are the M1 + minor reproductions, not just the four Instruments scenarios). Specifically items 1 (M1 race), 2 (mermaid global leak), 4 (marker-shaped string in user content), 7 (scope_hint malicious injection) are reproducible smoke tests that complement Instruments.

4. **Pre-merge fix decision (out of test-audit scope, flagged for the user):** code-audit.md flagged M1 as "recommend addressing before merge". Test-audit confirms M1 cannot be regressed-against by an automated test pre-merge (no test target). Decision lies with the user/Boris: either land the M1 fix before merge (recommended), or accept the silent-UX-wrongness risk and rely on T12 manual reproduction. This is NOT a test-audit blocker; it's a code-quality one already raised by code-reviewer.

---

## Verdict

**DEFERRAL JUSTIFIED**

All 5 checks PASS. No tests need to be raised from follow-up to blocking-pre-merge. The compensating verification (committed fixtures + dual audit hand-traces + exhaustive `[weak self]` review + four-scenario manual Instruments check + manual smoke for the M1 UX issue) substitutes adequately for the deferred test target. The follow-up is well-scoped (7 modules covering every critical path), well-owned ("Boris or first contributor to touch insight code path post-merge"), and well-dated ("within 2 weeks after merge, target 2026-05-14").

**Action items (none blocking):**
1. (Recommended, 5-minute edit) Add manual-Instruments-rerun note to `tasks/todo.md` under XCTest setup item.
2. (Optional) Expand follow-up scope with 4 nice-to-have additional test modules listed in Recommendations §2.
3. (Out of test-audit scope) Decide on M1 pre-merge fix vs accept-and-rely-on-manual-smoke. Code-audit.md recommends the fix; this audit does not require it.

**This audit does NOT block Pre-deploy QA (Task 12).** T12 may proceed.

---

*End of audit report.*
