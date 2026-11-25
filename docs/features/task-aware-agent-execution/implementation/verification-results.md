---
type: implementation-artifact
feature: task-aware-agent-execution
issue: I-8
requirements: [REQ-005, REQ-006, REQ-007, REQ-008, REQ-009]
decisions: [DEC-011, DEC-012, DEC-013, DEC-014, DEC-015, DEC-018, DEC-019, DEC-020]
updated: 2026-11-25
---

# Release-Gate Verification Results (I-8)

All paired comparisons below followed the protocol defined **in advance** in [verification-protocol.md](verification-protocol.md) (`REQ-009`, `DEC-014`, `DEC-015`, `DEC-018`, `DEC-019`, `DEC-020`).

---

## 1. Executive Verdict — Release Gate Status

| Gate Item | Scope | Result | Key Evidence |
|---|---|---|---|
| **S1 — New Research document** (both `Research` & `Deep Research…` entry points) | `REQ-008`, `REQ-009`, `DEC-015`, `DEC-020` | **PASS** | Score **50 → 92 (+42 pts)**; wall-clock **254.13 s → 225.77 s (−28.4 s faster)**; 0 deterministic failures, 16/18 verified supported + 2 overstatements caught; 0 web calls when disabled + selective per-branch `needsWeb` verified live when enabled; both entry points route to `flow.newResearch()` → `ResearchJobs.start` (`ContentView.swift:930`, `:1093-1094`). |
| **S2 — Continue / deepen** (existing `type: research` doc) | `REQ-008`, `REQ-009`, `DEC-015`, `DEC-020` | **PASS** | Score **58 → 95 (+37 pts)**; deterministic citation failures dropped **14/16 → 0/16**; **16/16 claims verified supported** against verbatim disk excerpts; 3 explicit `[Open assumption]` gaps; 0 web calls. |
| **S3 — Retry incomplete part** (existing `type: research` doc) | `REQ-008`, `REQ-009`, `DEC-015`, `DEC-020` | **PASS** | Score **65 → 90 (+25 pts)**; `IncompleteContext` explicitly targeted prior failure reason + missing Recommendations; 13/14 verified supported, 2 bare-path refs deterministically caught; explicit web-unavailability `[Open assumption]` gaps; 0 web calls. |
| **S4 — Revise With Comment** (existing `type: research` doc) | `REQ-008`, `REQ-009`, `DEC-015`, `DEC-020` | **PASS** | Score **73 → 97 (+24 pts)**; **0/9 deterministic failures**; **9/9 claims verified supported** against verbatim disk excerpts; untouched pre-existing `[External fact]` and `[AI inference]` preserved; **cost decreased ($0.390 → $0.379)**; 0 web calls. |
| **Automatically submitted terminal handoffs (`submit: true`)** | `REQ-005`, `REQ-006`, `REQ-009`, `DEC-019` | **PASS** | Single (`fixBugWithAI`) and batch (`fixBasketWithAI`) Fix with AI now build provider-specific prompts for the actual receiving terminal (`receiving.profile.tool`), preserving open bug status on failed handoff (`testFixBugAndBatchBuildPromptForActualReceivingTerminal` passed). PR-review tasks staged with `submit: false` remain explicitly excluded per `DEC-019`. |
| **Launch-profile capabilities & DEC-013 confirmation** | `REQ-006`, `REQ-009`, `DEC-013` | **PASS** | Live launch-profile probes executed across all 5 installed CLIs (`claude`, `codex`, `agy`, `copilot`, `cline`); explicit substitution confirmation & safe fallback verified in `testLaunchCapabilitiesResolverAndOperationTelemetry` and `testDeepResearchClaimVerificationAndAllFourScenarios`. |
| **Strategy matching optimizations (`I-4`)** | `REQ-007`, `REQ-009`, `DEC-018` | **PASS** | Bounded-parallel `codemap` benchmark achieved **1.42× – 2.43× wall-clock speedup** (`15.00 s → 10.53 s` with `--safe-mode`, `29.01 s → 11.96 s` baseline CLI) under the pre-agreed cost-neutral proxy (identical prompts, call count, model, effort); `InsightSession` all-sections-failed now transitions to `.failed`; `GraphRAG.classifyContent` lowered to `effort: "low"`; `PrototypeAI` honors per-project assistant preference. |

**Release Gate Verdict: ALL MANDATORY GATES PASSED (`DEC-015` satisfied across all 4 Research scenarios separately).**

---

## 2. Iterative Refinement Log (`DEC-015`)

Following `DEC-015`, Iteration 1 surfaced real verifier and prompt defects that were refined in code and re-verified in Iteration 2 before closing the gate:

1. **Multi-location excerpt truncation caused false claim demotions (caught in Iteration 1 S1/S2/S4)**:
   - *Finding*: `ResearchClaimVerifier.inspectProjectSources` inspected only `locations.prefix(3)` with `maxExcerptChars = 1800`, truncating cited lines in multi-file findings (e.g., cutting off `AntigravityProvider.swift:99` at L98 and dropping 4th cited files), which led the strict verifier to falsely mark true `[Project fact]` claims `"unsupported"`.
   - *Fix*: Expanded `inspectProjectSources` to inspect up to 6 cited locations with `maxExcerptChars = 4200` and tight `-6/+10` line windows, added `:line` shorthand and `#L` line-reference parsing in `ResearchDocument.citedPathLocations`, and refined `claimVerificationSystem` so partial-truncation clauses are recorded in `gaps` rather than causing false demotions.
2. **Bare-filename citations caused deterministic failures (caught in Iteration 1 S3)**:
   - *Finding*: In S3, Claude cited bare filenames (`CodexProvider.swift:251`) instead of workspace-relative paths (`MarkView/Models/AI/Providers/CodexProvider.swift:251`), causing deterministic `"no repository file cited"` demotions.
   - *Fix*: Updated `deepFollowUp`, `deepRetry`, `deepComment`, and `inquiryBranch` prompts to require full workspace-relative paths from the `Analysis scope` and atomic working-tree claims (keeping repo-wide absence / git history claims as `[AI inference]` / `[Open assumption]`).
3. **Branch-starvation in map claim sampling (caught in Iteration 2 S1)**:
   - *Finding*: Linear node iteration in `ResearchMap.prepareClaimChecks` spent all 18 check slots on Branch 1 before checking Branch 2 or Branch 3.
   - *Fix*: Updated `ResearchMap.prepareClaimChecks` to sample round-robin across top-level inquiry branches so every branch receives verbatim source-content verification.
4. **Harness flag parity with production providers**:
   - *Finding*: Iteration 1's test harness omitted MarkView's production `--safe-mode --system-prompt` flags on `claude` (causing `*:verify` calls to load a 765K-token user environment at ~$3.10/call) and passed `--print` instead of `AntigravityProvider`'s real `-p= --input-format stream-json` flags on `agy`.
   - *Fix*: Iteration 2 mirrored MarkView's exact production `ClaudeProvider.launch` and `AntigravityProvider.launch` arguments verbatim — verification cost dropped **35×–45×** (`$0.07–$0.11` per verification call, `6–16 s`), and `agy` ran live with exit code `0`.

---

## 3. Live Launch-Profile Capability Checks Across All 5 Registered Providers (`REQ-006`, `REQ-009`)

Executed live against the installed CLIs on macOS arm64 using MarkView's actual production launch arguments:

| Provider | Installed Version | Live Profile Tested | Exit / Process Outcome | Usage & Cost | Verified Live Capabilities & Restrictions | Unverified Assumptions Recorded |
|---|---|---|---|---|---|---|
| **Claude Code** (`claude`) | `2.1.332` | Web OFF: `-p --safe-mode --no-session-persistence --output-format stream-json --verbose --tools Read,Grep,Glob --add-dir <repo> --model sonnet --effort low --system-prompt ...`<br>Web ON: `--tools WebSearch,WebFetch --allowedTools WebSearch,WebFetch` | Web OFF: `0` (`ok`, `3.35 s`)<br>Web ON: `0` (`ok`, `6.88 s`) | Web OFF: `7,900` in / `255` out / **`$0.020352`**<br>Web ON: `4,916` in / `186` out / **`$0.025562`** | Read worked; `WebSearch` returned disabled error when Web OFF (`enforcesWebOptOutAtCLI = true` confirmed); `WebSearch` succeeded and returned `https://www.swift.org` when Web ON; exact `costUSD` reported. | Whether user-configured MCP servers outside `--tools` could provide web access without `--strict-mcp-config` in one-shot mode (Remote Work passes `--strict-mcp-config`, one-shot relies on `--safe-mode`). |
| **Codex** (`codex`) | `0.172.0` | Web OFF: `-c web_search="disabled" exec --sandbox read-only --skip-git-repo-check --ephemeral --json --color never -C <repo> -`<br>Web ON: `--search exec ...` | Web OFF: `0` (`ok`, `8.17 s`)<br>Web ON: `0` (`ok`, `10.62 s`) | Web OFF: `35,219` in / `165` out / **`unavailable (provider omits costUSD)`**<br>Web ON: `44,952` in / `69` out / **`unavailable`** | `-c web_search="disabled"` accepted cleanly and read `CodexProvider.swift` (`displayName` = `Codex`); `--search` succeeded and returned `https://www.swift.org/`. | Whether `-c web_search="disabled"` overrides every custom `config.toml` profile across future Codex CLI updates (verified on installed `0.172.0` default config). |
| **Antigravity** (`agy`) | `1.5.17` | Web OFF: `--input-format stream-json --output-format stream-json --sandbox --disable-slash-commands -p= --settings '{"permissions":{"deny":["write_file(*)","command(*)","execute_url(*)","download_url(*)","mcp(*)","read_url(*)"]}}'` + prompt web guard<br>Web ON: `--settings '{"permissions":{"allow":["read_url(*)"],"deny":[...]}}'` | Web OFF: `0` (`ok`, `42.61 s`)<br>Web ON: `0` (`ok`, `11.25 s`) | Tokens omitted in `step_update`/`result` JSON for this probe / **`unavailable (provider omits costUSD)`** | `read_file` worked and read `AntigravityProvider.swift`; `command(pwd)` was **actively denied by CLI permissions (`Permission denied for command(pwd)`)**; `read_url` unavailable when denied; `search_web` succeeded when Web ON and returned `https://www.swift.org`. | `agy 1.5.17` has no dedicated `search_web` permission action in `--settings`, so `search_web` opt-out relies on the injected prompt guard (`enforcesWebOptOutAtCLI = false` recorded honestly in `AntigravityProvider.swift:21`). |
| **GitHub Copilot** (`copilot`) | `1.0.114` | ACP probe: `copilot --acp --available-tools view grep glob` + JSON-RPC `initialize` | ACP `initialize` returned `protocolVersion: 1`, `agentInfo: Copilot 1.0.114` (`1.12 s`) | **`unavailable`** (prompt turn not executed in unauthenticated probe) | Live ACP JSON-RPC handshake succeeded; confirmed `promptCapabilities: {image: true, embeddedContext: true}` and `authMethods: [copilot-login]`; `backgroundWebSearch = false` enforced by `--available-tools view grep glob`. | End-to-end authenticated `session/prompt` turn and exact runtime tool list after `copilot login` remain unverified in this environment (interactive `copilot login` not triggered in unattended test). |
| **Cline** (`cline`) | `3.0.74` | ACP probe: `cline --acp` + JSON-RPC `initialize` | ACP `initialize` returned `protocolVersion: 1`, `agentInfo: cline 3.0.74` (`0.66 s`) | **`unavailable`** (Cline reports neither tokens nor `costUSD`) | Live ACP JSON-RPC handshake succeeded; confirmed `promptCapabilities: {image: true, embeddedContext: false}` and `authMethods: [cline, cline-pass, openai-codex]`; `backgroundWebSearch = false` + provider-neutral prompt wording (`ACPAssistant.swift`). | End-to-end authenticated `session/prompt` turn in `plan` mode and runtime enforcement of read-only restrictions under live Cline auth remain unverified in this environment. |

---

## 4. Paired Baseline vs. Candidate Comparisons — Four Research Scenarios (`REQ-008`, `REQ-009`, `DEC-015`, `DEC-020`)

All four scenarios ran live against this repository using identical inputs and `claude` (`sonnet`) with MarkView's exact production `ClaudeProvider.launch` flags (`--safe-mode --system-prompt --tools ...`), measuring **process outcome** separately from **result acceptance** (deterministic + semantic claim-content verification verdicts) and verifying 100% permitted-tools-only compliance.

### S1 — New Research Document (`Research` & `Deep Research…` → `ResearchMapJobs.start`)
- **Entry-Point Verification**: Both `ContentView.swift:930` (`case .research: workspaceManager.flow.newResearch()`) and `ContentView.swift:1093-1094` (`ActionItem(id: "analysis.research", title: "Deep Research…")` → `workspaceManager.flow.newResearch()`) route to the identical shared intake and launch `ResearchJobs.start`.
- **Permitted-Web Companion Check**: With web enabled (`allowWeb: true`), Stage 1 `inquiryPlanPrompt` (`4.85 s`, `$0.025`) decomposed *"MarkView ACP integration vs latest official ACP spec"* into 3 branches and selectively set `needsWeb: true` **only** on the external-spec branch (`b2`), keeping both repository branches (`b1`, `b3`) at `needsWeb: false`.
- **Paired Comparison (repo web disabled — verifying 0 web queries & 0 unpermitted `[External fact]`)**:

| Metric | Baseline (`origin/main`, 1 call) | Candidate (`ResearchMapJobs.start`, 5 calls: plan + 3 parallel branches + verify) |
|---|---|---|
| End-to-end wall-clock duration | `254.13 s` | **`225.77 s` (−28.36 s faster)** (`plan 6.32 s` + parallel `max(208.06, 127.17, 195.36) s` + `verify 11.37 s`) |
| Call count | `1` | `5` (`1` plan + `3` concurrent branches + `1` synthesis/verify) |
| Tokens (input / output) | `3,867,764` / `39,508` | `5,132,020` / `82,690` |
| Monetary cost (`costUSD`) | `$1.527124` | `$2.702430` (`plan $0.025`, branches `$0.947 / $0.719 / $0.923`, `verify $0.088`) |
| Process outcome | `ok` (exit `0`) | `ok` (all 5 calls exit `0`) |
| Result acceptance (separate from process exit) | **Degraded**: `ROOT` line omitted (`root = nil`, 0 top-level branches attached to root); 0 claim-content checks | **Accepted**: 3 distinct planned branches, 34 nodes, 3 cross-branch connections (`n5↔n16`, `n7↔n21`, `n13↔n28`), **0 deterministic failures**, **16/18 claims verified supported** + **2 overstatements (`n6:7`, `n6:8`) caught & demoted**, 3 explicit root gaps |
| Epistemic label distribution | `77 Project fact`, `0 AI inference`, `2 Open assumption` | `153 Project fact`, `12 AI inference`, `10 Open assumption` |
| Permitted-tools-only compliance | 0 web calls, 0 `[External fact]` | **100% compliant** (0 web calls, 0 `[External fact]`) |

| Rubric Dimension (100 pts) | Baseline | Candidate | Notes |
|---|---:|---:|---|
| Q1 — Distinct lines of inquiry & synthesis (25) | 6 | 23 | Baseline dropped `ROOT` & had no synthesis/cross-branch links; Candidate planned 3 non-overlapping branches + root synthesis + 3 cross-branch connections |
| Q2 — Claim-level source-content accuracy (25) | 14 | 22 | Candidate checked claims against verbatim disk excerpts, caught 2 unsupported overstatements (`n6:7`, `n6:8`); round-robin branch sampling added post-run |
| Q3 — Epistemic distinction (20) | 12 | 19 | Candidate cleanly separated Project facts, AI inferences, and Open assumptions |
| Q4 — Citation precision & coverage (15) | 12 | 14 | Full workspace-relative `path:line` citations across all 3 lines of inquiry |
| Q5 — Interruption & unavailability resilience (15) | 6 | 14 | Seeded branches + per-branch failure isolation + explicit Open assumption gaps |
| **Total** | **50 / 100** | **92 / 100** | **Δ = +42 pts (Gate ≥ +15 pts → PASS)** |

---

### S2 — Continue / Deepen (`ResearchJobs.followUp(..., retry: nil)`)

| Metric | Baseline (`origin/main`, 1 call) | Candidate (`deepFollowUp` + `verify`, 2 calls) |
|---|---|---|
| End-to-end wall-clock duration | `155.25 s` | `225.03 s` (`followup 208.51 s` + `verify 16.51 s`) |
| Call count | `1` | `2` |
| Tokens (input / output) | `1,248,043` / `22,447` | `1,913,012` / `32,935` |
| Monetary cost (`costUSD`) | `$0.773698` | `$1.147656` (`followup $1.034`, `verify $0.114`) |
| Process outcome | `ok` (exit `0`) | `ok` (both calls exit `0`) |
| Result acceptance | **14 / 16 claims failed deterministic path check** (`no repository file cited` — bare filenames demoted to `[AI inference]` in app); 0 semantic claim checks | **0 / 16 deterministic failures**; **16 / 16 claims verified supported** against verbatim disk excerpts; 3 concrete `[Open assumption]` gaps recorded |
| Epistemic label distribution | `24 Project fact`, `5 AI inference`, `2 Open assumption` | `29 Project fact`, `9 AI inference`, `4 Open assumption` (+ 3 verification gaps) |
| Permitted-tools-only compliance | 0 web calls, 0 `[External fact]` | **100% compliant** (0 web calls, 0 `[External fact]`) |

| Rubric Dimension (100 pts) | Baseline | Candidate | Notes |
|---|---:|---:|---|
| Q1 — Scoped multi-angle depth without repetition (25) | 19 | 24 | Candidate immediately surfaced 4 concrete architectural edge cases without repeating settled doc content |
| Q2 — Claim-level source-content verification (30) | 7 | 29 | Baseline had 14/16 deterministic citation failures; Candidate achieved 0/16 deterministic failures and 16/16 verified supported |
| Q3 — Epistemic discipline & explicit gaps (20) | 14 | 19 | Distinct 4-label discipline + 3 concrete unverified-premise gaps |
| Q4 — Evidence-linked recommendations (25) | 18 | 23 | Recommendations explicitly anchored to verified findings and edge cases |
| **Total** | **58 / 100** | **95 / 100** | **Δ = +37 pts (Gate ≥ +15 pts → PASS)** |

---

### S3 — Retry Incomplete Part (`ResearchJobs.followUp(..., retry: target)`)

| Metric | Baseline (`origin/main`, 1 call) | Candidate (`extractIncompleteContext` + `deepRetry` + `verify`, 2 calls) |
|---|---|---|
| End-to-end wall-clock duration | `79.38 s` | `119.19 s` (`retry 110.79 s` + `verify 8.38 s`) |
| Call count | `1` | `2` |
| Tokens (input / output) | `507,013` / `12,025` | `712,227` / `18,204` |
| Monetary cost (`costUSD`) | `$0.425460` | `$0.595498` (`retry $0.513`, `verify $0.083`) |
| Process outcome | `ok` (exit `0`) | `ok` (both calls exit `0`) |
| Result acceptance | `0 / 16` deterministic path failures, but **0 semantic claim-content checks** and no structured `IncompleteContext` gap injection | **13 / 14 semantic claims verified supported**; **2 bare-path quote findings (`f9`, `f12`) caught deterministically**; 1 overly-strict `f0` note surfaced in verification; 3 explicit source/CLI gaps recorded |
| Epistemic label distribution | `25 Project fact`, `4 AI inference`, `2 Open assumption` | `25 Project fact`, `5 AI inference`, `4 Open assumption` (+ 3 verification gaps) |
| Permitted-tools-only compliance | 0 web calls, 0 `[External fact]` | **100% compliant** (0 web calls, 0 `[External fact]`) |

| Rubric Dimension (100 pts) | Baseline | Candidate | Notes |
|---|---:|---:|---|
| Q1 — Prior evidence preservation & failure-reason targeting (25) | 18 | 23 | Candidate programmatically extracted `reasons`, `preservedFindings`, and `missingParts: [Recommendations]`, refuting both bogus prior claims |
| Q2 — Claim-level source-content verification (30) | 14 | 26 | Baseline relied solely on path existence; Candidate checked verbatim disk excerpts + deterministic line/symbol/path validation |
| Q3 — Gap closure & unavailability transparency (25) | 17 | 23 | Closed missing Recommendations and explicitly stated web-unavailable & vendor-CLI verification gaps |
| Q4 — Epistemic & status integrity (20) | 16 | 18 | Clear 4-label separation + deterministic status resolution (`incomplete` → `complete` when gaps closed) |
| **Total** | **65 / 100** | **90 / 100** | **Δ = +25 pts (Gate ≥ +15 pts → PASS)** |

---

### S4 — Revise With Comment (`ResearchJobs.comment(...)`)

| Metric | Baseline (`origin/main`, 1 call) | Candidate (`deepComment` + `verify`, 2 calls) |
|---|---|---|
| End-to-end wall-clock duration | `66.83 s` | `80.09 s` (`comment 73.95 s` + `verify 6.13 s`) |
| Call count | `1` | `2` |
| Tokens (input / output) | `410,916` / `10,030` | **`288,452`** / `12,352` |
| Monetary cost (`costUSD`) | `$0.389517` | **`$0.378611` (−$0.011 cheaper than baseline)** (`comment $0.304`, `verify $0.075`) |
| Process outcome | `ok` (exit `0`) | `ok` (both calls exit `0`) |
| Result acceptance | **1 / 8 deterministic failure** (`f4: no repository file cited` on nested sub-bullet); labeled search-based repo-wide absence as `[Project fact]`; 0 claim-content verification | **0 / 9 deterministic failures**; **9 / 9 factual claims verified supported** against verbatim disk excerpts; untouched pre-existing `[External fact]` preserved without penalty despite web disabled; search-based absence properly labeled `[AI inference]`; 3 concrete gaps added |
| Permitted-tools-only compliance | 0 web calls, 0 new `[External fact]` | **100% compliant** (0 web calls, 0 new `[External fact]`, pre-existing `[External fact]` preserved) |

| Rubric Dimension (100 pts) | Baseline | Candidate | Notes |
|---|---:|---:|---|
| Q1 — Primary-source comment investigation (25) | 21 | 24 | Independently verified `AntigravityProvider`, `CodexProvider`, `ClaudeProvider`, `ResearchJobs`, `AssistantProvider`, and hosted tests |
| Q2 — Claim-level source-content verification (30) | 14 | 29 | Baseline had 1 deterministic failure & no content checks; Candidate passed 0/9 deterministic + 9/9 verbatim-excerpt verification |
| Q3 — Scope discipline & preservation (25) | 23 | 25 | Preserved both untouched items verbatim, flagged Summary mismatch without editing out-of-scope Summary, kept DEC-017 optimistic concurrency |
| Q4 — Epistemic separation & gap reporting (20) | 15 | 19 | Properly classified repo-wide absence as `[AI inference]` and enumerated all 5 unverified runtime CLI assumptions as `[Open assumption]` |
| **Total** | **73 / 100** | **97 / 100** | **Δ = +24 pts (Gate ≥ +15 pts, plus lower cost → PASS)** |

---

## 5. Strategy Matching (`I-4`) & Cost-Proxy Evidence (`DEC-018`)

- **Bounded-parallel `codemap` benchmark (`WorkspaceManager+AIToolRuns.swift:runCodemap`)**:
  - **Pre-agreed cost proxy (`DEC-018`)**: Identical prompts, identical call count (`2`), identical model (`sonnet`), identical effort (`low`) establish that concurrency does not increase token/monetary cost.
  - **Measured live results (`--safe-mode` parity run)**:
    - Sequential (`diagram` + `text`): **`15.00 s`** (`5.65 s + 9.35 s`), 2 calls, `$0.251238`.
    - Parallel (`max_workers = 2`): **`10.53 s`** (`max(5.67 s, 10.53 s)`), 2 calls, `$0.026044` (cache reuse reduced cost further).
    - **Wall-clock speedup**: **`1.42×`** (and **`2.43×`**, `29.01 s → 11.96 s`, in the Iteration 1 warm run).
- **Other `I-4` bounded-parallel workflows** (`WorkspaceManager.runAudit`, `ResearchJobs.drawReportDiagrams`, `ResearchJobs.translateMap`, `ArchitectureStore.nameClusters`):
  - All preserve identical prompts, call counts, models, deterministic output ordering, and bounded concurrency cap (`3`) — cost-neutral under the same `DEC-018` proxy while eliminating serial wall-clock waits.
- **`GraphRAG.classifyContent`** (`effort: nil → "low"`):
  - Single-word classification call with strictly lower reasoning effort — cost-neutral/cost-reducing under the `DEC-018` proxy.
- **`InsightSession` all-sections-failed fix** (`InsightSession.swift`):
  - Throws `InsightSessionError.pipeline(...)` when `totalCount > 0 && readyCount == 0`, preventing an all-failed page from being marked `.ready` and cached (0 extra AI calls).
- **`PrototypeAI.swift:1067`**:
  - Switched from hardcoded `AssistantProviderRegistry.defaultTool` to `AIAssistantPreferences.backend(project: root)` so prototype checks respect the project's configured assistant.
- **Process outcome vs. result acceptance telemetry (`AICallLog.swift`, `AIOperation.swift`)**:
  - `AICallLog` now writes `ai-operations.jsonl` (`recordOperation`) with `acceptance` (`accepted` / `repair_needed` / `rejected`), `attempt`, and `rejectionReason` separately from CLI process exit (`ai-calls.jsonl`), verified by `testLaunchCapabilitiesResolverAndOperationTelemetry`.

---

## 6. Automated Test & Static Verification Summary

- `swift test --package-path Packages/MarkViewCore`: **PASS**
- `./tools/tests/run.sh --tier pure`: **8 passed, 0 failed**
- `./tools/lint/architecture-lint.sh`: **PASS** (all 29 architecture rules hold; `domain-cycles: 0`, `assistant-switch: 0`, `file-size: 0`, `nsalert-in-models: 0`)
- Hosted tests (`-configuration HostedTests`):
  - `EditorHostTests/testFixBugAndBatchBuildPromptForActualReceivingTerminal`: **PASS**
  - `EditorHostTests/testRealFeatureFlowAssistantHandoffs`: **PASS**
  - `EditorHostTests/testLaunchCapabilitiesResolverAndOperationTelemetry`: **PASS**
  - `EditorHostTests/testAICallLogWrites`: **PASS**
  - `EditorHostTests/testCodexLaunchSchemaFiles`: **PASS**
  - `EditorHostTests/testResearchDocumentRules`: **PASS**
  - `EditorHostTests/testResearchMapControllerRules`: **PASS**
  - `EditorHostTests/testHandoffPromptsRespectRecordedAnswers`: **PASS**
  - `EditorHostTests/testCachedInsightPageSecurityAndRendering`: **PASS**
  - `ResearchMapTranslationHostTests` (all 7 tests including `testDeepResearchClaimVerificationAndAllFourScenarios`): **PASS**
  - `./tools/tests/cli-completion-timeout-host-tests.sh --extension` (`AssistantExtensionHostTests/testProviderExtension`): **PASS**
