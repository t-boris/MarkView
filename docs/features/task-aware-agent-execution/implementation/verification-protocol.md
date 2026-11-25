---
type: implementation-artifact
feature: task-aware-agent-execution
issue: I-7
requirements: [REQ-008, REQ-009]
decisions: [DEC-012, DEC-013, DEC-014, DEC-015, DEC-018, DEC-019, DEC-020]
updated: 2026-11-25
---

# Baseline & Candidate Verification Protocol (I-7)

Defined **before** running paired baseline vs. candidate comparisons (`REQ-009`, `DEC-014`, `DEC-015`, `DEC-018`, `DEC-019`, `DEC-020`).

---

## 1. Scope & Exclusions

### Mandatory First-Release Scope
1. **Four Research scenarios — verified separately against each scenario's own current behavior (`DEC-015`, `DEC-020`)**:
   - **S1 — New Research document**: Creating a new research document via **both** `Research` (`ContentView.swift:930`) and `Deep Research…` (`ContentView.swift:1093`) entry points through the shared intake (`ResearchMapJobs.start`).
   - **S2 — Continue / deepen**: Appending a follow-up to an existing `type: research` document (`ResearchJobs.followUp(..., retry: nil)`).
   - **S3 — Retry incomplete part**: Retrying an incomplete section of an existing `type: research` document (`ResearchJobs.followUp(..., retry: target)`).
   - **S4 — Revise With Comment**: Revising a selected section of an existing `type: research` document (`ResearchJobs.comment(...)`).
2. **Automatically submitted terminal handoffs (`submit: true`, `DEC-019`)**:
   - Single Fix with AI (`FeatureFlowCoordinator.fixBugWithAI`) and Batch Fix with AI (`FeatureFlowCoordinator.fixBasketWithAI`) when normal routing picks an open terminal whose provider differs from the project default, plus failed-handoff status integrity (bugs stay open, never marked `fixing`).
3. **Launch-profile capability enforcement & substitution confirmation (`DEC-013`, `REQ-006`)**:
   - Live launch-profile capability checks across all 5 installed providers (`claude`, `codex`, `copilot`, `cline`, `agy`).
   - Explicit confirmation gating when an explicitly selected provider lacks a needed capability (confirmed substitution, declined substitution fallback, cancellation, and no-compatible-provider behavior).
   - Explicit record of any capability assumptions that remain unverified.
4. **Strategy optimizations (`REQ-007`, `I-4`)**:
   - Bounded concurrency pipelines (`WorkspaceManager.runCodemap`, `WorkspaceManager.runAudit`, `ResearchJobs.drawReportDiagrams`, `ResearchJobs.translateMap`, `ArchitectureStore.nameClusters`), `InsightSession` all-sections-failed fix, and `GraphRAG.classifyContent` low-effort tuning.

### Explicitly Excluded (`DEC-019`)
- Manually submitted terminal drafts staged with `submit: false` — specifically PR-review task lists (`CodeAndXRayCoordinator.swift:559`), browser element-picker pastes, voice dictation pastes, and dropped file paths — are outside mandatory inventory and first-release verification even if the user later submits them manually.

---

## 2. Measurement Contract & Pre-Agreed Cost Proxies (`REQ-009`, `DEC-014`, `DEC-018`)

Every paired comparison records:
- **End-to-end duration**: wall-clock seconds from start to final verified artifact.
- **Call count**: total CLI/ACP invocations, broken down by stage.
- **Usage & cost**: `inputTokens`, `outputTokens`, and `costUSD` when reported by the provider; explicitly marked `unavailable` when omitted by the provider (e.g., Codex/Antigravity/Copilot report tokens with `costUSD: nil`; Cline reports neither tokens nor cost).
- **Process outcome vs. result acceptance (assessed separately)**:
  - Process outcome: CLI exit status (`ok` / `failed` / `timeout` / `cancelled`, logged in `ai-calls.jsonl`).
  - Result acceptance: `AIOperation` parse/validation/claim-verification acceptance (`accepted` / `repair_needed` / `rejected`, logged in `ai-operations.jsonl`, plus verified vs. demoted claim counts for Research).
- **Permitted-tools-only check**: confirms every run used only sources and tools permitted by repository settings (`RepositoryWebPolicy.isWebDisabled`) and available to the actual launch profile.

### Pre-Agreed Cost Proxies (`DEC-018`)
1. **Bounded-parallel batch workflows (`runCodemap`, `runAudit`, `drawReportDiagrams`, `translateMap`, `nameClusters`)**:
   - **Proxy**: Identical prompts, identical call count, identical model, and identical effort level on the same input establish that total token/monetary cost did not increase (only concurrency changed, reducing wall-clock duration).
2. **Lower-effort single call (`GraphRAG.classifyContent`: `effort: nil` -> `"low"`)**:
   - **Proxy**: Identical single call on the same model with strictly lower reasoning effort establishes that cost did not increase.
3. **All four Deep Research scenarios (S1, S2, S3, S4)**:
   - **No cost-neutral proxy applies.** Deep Research adds multi-inquiry decomposition/parallelism and/or claim-level source-content verification, so **every one of S1, S2, S3, and S4 MUST pass by demonstrating a material quality gain** against its own current baseline under the rubrics below (whether cost is directly measured via Claude `costUSD` or unavailable on another provider).

---

## 3. Representative Paired Tasks & Comparable Inputs

All four Research comparisons run live against this repository (`MarkView`, commit `93df066b` / feature branch files) with identical inputs for baseline vs. candidate, using the same provider and model (`claude` `sonnet`, which reports exact `inputTokens`, `outputTokens`, and `costUSD`), plus cross-provider capability verification across `claude`, `codex`, `copilot`, `cline`, and `agy`:

- **S1 (New Research document — broad question)**:
  - Question: *"How does MarkView launch and restrict AI CLI providers across background runs, interactive terminals, and Remote Work, and where do provider capabilities or web-search controls diverge?"*
  - Comparable inputs: Same repository root, same target files (`MarkView/Models/AI/CLICompletion.swift`, `MarkView/Models/AI/ACPAssistant.swift`, `MarkView/Models/Research/ResearchJobs.swift`), repository web search **disabled** (verifying zero web tool calls and zero fabricated `[External fact]` claims) AND a companion permitted-web check confirming web search runs only when permitted & available.
  - Both UI entry points (`ContentView` `WelcomeActionID.research` and `ProjectToolsMenuContent` `"analysis.research"` / `"Deep Research…"`) verified to route through the identical shared intake (`flow.newResearch()` -> `ResearchJobs.start`).
- **S2 (Continue / deepen on existing `type: research` document)**:
  - Input document: Representative existing `type: research` document summarizing MarkView's `AIOperation` and `AICallLog` pipeline (with settled initial findings).
  - Follow-up question: *"How do terminal handoffs (`sendToAssistant`, `HandoffPrompt`, `BatchFixPrompt`) interact with terminal routing and lifecycle status transitions, what edge cases exist when routing picks another provider, and what gaps remain unverified?"*
  - Comparable inputs: Identical existing research document, repository web disabled, same model.
- **S3 (Retry incomplete part on existing `type: research` document)**:
  - Input document: Representative existing `type: research` document whose latest section is marked `> ⚠️ Incomplete: cancelled after 1:20; web search unavailable` with 2 usable partial findings (one valid `Project fact`, one hallucinated claim with an out-of-range line number) and missing Recommendations.
  - Retry target: The incomplete section (`retry != nil`).
  - Comparable inputs: Identical incomplete document, same question, same model.
- **S4 (Revise With Comment on existing `type: research` document)**:
  - Input document: Representative existing `type: research` document with `## Summary`, `## Findings` (containing an inaccurate claim about `ResearchJobs.web` / `AntigravityProvider` alongside accurate untouched findings), and `## Recommendations`.
  - Selected passage & comment: User selects the inaccurate finding in `## Findings` and comments: *"Check `ResearchJobs.swift` and `AntigravityProvider.swift` directly — does `AntigravityProvider` really lack web search, and how is web opt-out enforced across Claude, Codex, and Antigravity? Keep the other findings unchanged."*
  - Comparable inputs: Identical document, identical passage & comment, same model.

---

## 4. Workflow-Specific Quality Rubrics & Material-Gain Thresholds

Each Research scenario is scored on a **100-point rubric** designed before execution:

### S1 — New Research Document (100 pts)
- **Q1 — Distinct Lines of Inquiry & Synthesis (25 pts)**: ≥2 distinct, non-overlapping top-level lines of inquiry + synthesized root summary integrating findings across branches + cross-branch connections.
- **Q2 — Claim-Level Source-Content Accuracy (25 pts)**: Every `[Project fact]` checked against actual cited file contents (valid path, line within file bounds, cited symbols present, claim semantically supported by verbatim excerpt); zero unpermitted `[External fact]`.
- **Q3 — Epistemic Distinction (20 pts)**: `[Project fact]`, `[External fact]` (only when permitted & available), `[AI inference]`, and `[Open assumption]` remain clearly separated; unsupported claims demoted with explicit reason.
- **Q4 — Citation Precision & Coverage (15 pts)**: Concrete `path:line` citations across multiple relevant modules (not vague file-only summaries).
- **Q5 — Interruption & Unavailability Resilience (15 pts)**: Preserves usable partial evidence and records explicit `[Open assumption]` gaps when interrupted or when sources are unavailable.
- **Material-Gain Gate**: `Candidate - Baseline >= +15 pts` AND `Candidate Q2 >= Baseline Q2` AND 100% permitted-tools-only compliance.

### S2 — Continue / Deepen (100 pts)
- **Q1 — Scoped Multi-Angle Depth Without Repetition (25 pts)**: Directly deepens the follow-up question across implementation, edge cases, and trade-offs without repeating settled original document content.
- **Q2 — Claim-Level Source-Content Verification (30 pts)**: Every `[Project fact]` verified against verbatim file excerpts (zero ungrounded line numbers/symbols/hallucinated behaviors slipping through as `[Project fact]`); zero unpermitted `[External fact]`.
- **Q3 — Epistemic Discipline & Explicit Gaps (20 pts)**: Distinct 4-label usage plus concrete `[Open assumption]` entries for unverified premises or unavailable sources.
- **Q4 — Evidence-Linked Recommendations (25 pts)**: Concrete next steps tied directly to verified findings.
- **Material-Gain Gate**: `Candidate - Baseline >= +15 pts` AND `Candidate Q2 >= Baseline Q2` (with 0 unverified hallucinated claims kept as `[Project fact]`) AND 100% permitted-tools-only compliance.

### S3 — Retry Incomplete Part (100 pts)
- **Q1 — Prior Evidence Preservation & Failure-Reason Targeting (25 pts)**: Explicitly addresses the recorded `> ⚠️ Incomplete:` reason and missing parts while preserving valid prior findings (and re-checking / demoting bad prior claims).
- **Q2 — Claim-Level Source-Content Verification (30 pts)**: All factual claims checked against actual cited file excerpts and permitted tools.
- **Q3 — Gap Closure & Unavailability Transparency (25 pts)**: Completes missing Summary/Findings/Recommendations and explicitly documents any still-unavailable sources as `[Open assumption]`.
- **Q4 — Epistemic & Status Integrity (20 pts)**: All 4 labels distinguishable; document status accurately reflects resolution or remaining gaps.
- **Material-Gain Gate**: `Candidate - Baseline >= +15 pts` AND `Candidate Q1 + Q2 > Baseline Q1 + Q2` AND 100% permitted-tools-only compliance.

### S4 — Revise With Comment (100 pts)
- **Q1 — Primary-Source Comment Investigation (25 pts)**: Verifies both the user's comment and existing text directly against repository/permitted sources without blindly trusting either.
- **Q2 — Claim-Level Source-Content Verification (30 pts)**: Revised factual claims verified against actual verbatim cited file excerpts; no unsupported new `[Project fact]` or unpermitted `[External fact]` slips through.
- **Q3 — Scope Discipline & Preservation (25 pts)**: Revises only what the comment concerns, preserving accurate untouched findings and DEC-017 optimistic concurrency safety.
- **Q4 — Epistemic Separation & Gap Reporting (20 pts)**: Keeps all 4 labels clear and notes any unavailable/unverified gap explicitly.
- **Material-Gain Gate**: `Candidate - Baseline >= +15 pts` AND `Candidate Q2 >= Baseline Q2` AND untouched items preserved AND 100% permitted-tools-only compliance.

### Release Gate Rule (`DEC-014`, `DEC-015`, `DEC-018`)
- Every confirmed improvement in first-release scope must pass its gate.
- All four Research scenarios (**S1, S2, S3, S4**) must pass **separately**. If any scenario fails, refine its deep workflow and re-run its paired comparison until all four pass before release.
