# MarkView — Follow-up Tasks

## Done 34: Voice input for intake text prompts (2026-09-26, issue #21, 2.16.0, not committed)

Spec: docs/features/voice-input-for-text-prompts (REQ-001…004, DEC-001…011).
User choice: the mic goes on the intake sheet's text field only (New Feature / New Bug /
I Need to Understand) — the intake sheet has no separate answer fields; Feature-tab and bug
question answers stay out (DEC-009).

- [x] `WhisperClient`: one recording app-wide (starting one cancels the other), `cancel()`
      discards audio and any in-flight transcription, recording capped at 10 min
      (`record(forDuration:)` — Terminal had no limit), upload timeout scales with size
- [x] `DictationController` (intake): idle / recording (elapsed, 30 s warning, auto-stop at the
      cap) / transcribing; inline error, "No speech recognized", denied-permission flag
- [x] `DictationButton` + status line: shown only with an OpenAI key (@AppStorage, live);
      key removed → cancel
- [x] Insert at the cursor of the focused field (NSTextView `insertText`), else append;
      never replaces the field
- [x] `IntakeSheet`: mic on the text field; Esc / Cancel cancels dictation first, then closes;
      closing the sheet cancels
- [x] Settings help text + README: audio goes to OpenAI, billed to the key, mic appears in intake
- [x] Spec: DEC-012 (field scope), REQ-001 aligned, status implemented
- [x] `tools/tests/dictation-insertion-tests.sh`: cursor insert, selection, spacing, undo, append
- [x] Build (Debug, no warnings in changed files)
- [x] Review fixes (2.16.1): cancel during the permission prompt no longer starts recording; one
      recorder even with a double start; insertion only into the sheet's window; no
      "cancelled" error; self-test reports an interruption
- [ ] Manual check in the app with a microphone (Boris)

## Done 33: Requirements approved when Explore ends (2026-09-26)

Nothing set `approved` automatically: Explore made `draft`, Resolve downgraded `approved → review`,
Build asked to approve per file; readiness ("Requirements approved") never reached 100 %.
User: leaving Explore approves; requirements from AI-decided questions are approved too.

- [x] `FeatureStore.finishExplore` / `approveRequirements`; `Feature.isPastExplore`, `discoveryDone`
- [x] Leaving Explore calls it: "Decide the rest and finish", "Go to Review", switching the stage tab
      away from Explore once discovery is done, "Run review" once discovery is done
- [x] Requirements created after Explore (resolution, consolidation, from a document) start `approved`
- [x] No `approved → review` downgrade on refinements / resolved findings (delegation = approval)
- [x] Build: "N not approved · Approve all" instead of the per-file hint
- [x] Build (shared tree, succeeds)
- [ ] Manual check in the app

## Done 32: Automatic lifecycle capture — spec ready, implementation (with model), PR/commit review, CI, merge (2026-09-26, not committed, version bump pending)

Report: "Implement with AI" recorded nothing; spec ready never fired; merge/CI not tracked.
Root cause of spec ready: no code sets status `ready` (Create issues: review → implementing).
User choices: GitHub's own times; implementation finished on status `implemented` AND PR opened;
PRs linked by closing the feature's issues; spec ready = status ready or readiness 100 %, fallback at
hand-off; no-PR flow: commits on main naming the feature folder / issues. See DEC-016.

- [x] `LifecycleLog.record(at:)` for automatic events (manual stays now)
- [x] `Models/LifecycleCapture.swift`: CLI model probe (Claude/Codex session logs), GitHub GraphQL
      query + parser, git commit parser/matcher, Actions runs parser
- [x] `FeatureStore`: spec ready (ready / 100 % / hand-off fallback), implementation finished on
      `implemented`, `recordImplementationStarted`, GitHub sync (on `GitHubStore.onPoll`, throttled to
      idle interval), git scan of the default branch (~1/min), CI for merged commits
- [x] `WorkspaceManager.implementWithAI` records the start for the session that got the prompt
- [x] DEC-016; lessons
- [x] `tools/tests/lifecycle-tests.sh` — 54 checks pass; GraphQL query verified live against the repo;
      commit matcher on real `git log` finds only c3d4f61 for the lifecycle feature
- [x] Build: succeeds (isolated worktree, then the shared tree once the quota-tracker files landed)
- [ ] Minor version bump at commit time (batch with the quota tracker's bump)
- [ ] Manual check in the app: Implement with AI on a feature → event with model after the CLI replies

## Done 31: AI agent usage & quota tracker (docs/features/ai-agent-usage-quota-tracker-codex-claude-code, 2.14.0)

Spec: REQ-001…006, DEC-001…016, plan I-1…I-7. User answers (2026-09-26): chips in the right panel's
Terminal tab header; no-limit state sums local usage for **today** (since local midnight); Claude Code
credentials read silently with `/usr/bin/security find-generic-password -w` (read-only, no prompt).

### Verified data sources (on this machine)
- Claude official: `GET api.anthropic.com/api/oauth/usage` (Bearer + `anthropic-beta: oauth-2025-04-20`)
  → `limits[]` {kind session|weekly_all|weekly_scoped, percent, resets_at, scope.model.display_name};
  legacy `five_hour`/`seven_day`/`seven_day_opus`/`seven_day_sonnet` {utilization, resets_at}.
  Token: Keychain "Claude Code-credentials" → `claudeAiOauth.accessToken`/`expiresAt` (ms).
- Codex official: `GET chatgpt.com/backend-api/wham/usage` (Bearer + `ChatGPT-Account-Id`) →
  `rate_limit.primary_window|secondary_window` {used_percent, limit_window_seconds, reset_at}.
  Token: `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id`.
- Claude local: `~/.claude/projects/**/*.jsonl`, `type=assistant` lines, `message.usage` (input, output,
  cache_creation, cache_read), duplicated per content block → dedupe by `message.id:requestId`.
  No per-message cost in current versions (only per-session cumulative `cost-state`) → USD only if a
  line carries top-level `costUSD` (older CLIs).
- Codex local: `~/.codex/sessions/**/*.jsonl`, `event_msg` `token_count` with cumulative
  `info.total_token_usage.total_tokens` → per-file deltas. No cost.

### Design
- `Models/AgentUsage.swift` (pure, Foundation only): agents, windows, levels 80/95, headline window,
  fallback limit + window math (anchor + n·period, month clamping), pace, state precedence,
  official response parsers, formatting.
- `Models/AgentUsageLogs.swift` (Foundation only): incremental per-file JSONL reader (byte offsets,
  complete lines only), line parsers, dedupe; unreadable/unparseable → error, never zero.
- `Models/AgentUsageTracker.swift` (@MainActor singleton): credentials (read on each poll, never
  stored/logged, refresh token never used), ephemeral URLSession, 5-min poll only while a Terminal tab
  is visible and the app is active, 60 s manual cooldown, backoff 5→30 min + Retry-After, FSEvents on
  the log dirs debounced to 30 s, in-memory cache, stale after 15 min, 401/expired → fallback + hint.
- `Views/AgentUsageViews.swift`: header chips (ViewThatFits full/short), popover (windows, remaining
  in the limit's unit, reset, source, pace, local figures, updated N min ago, hint + retry, refresh),
  limit form. Settings → DDE: show/hide per detected agent.

### Tasks
- [x] T1 Pure model + parsers (`AgentUsage.swift`) — I-1, I-3 math, I-4 parsing
- [x] T2 Local log reader (`AgentUsageLogs.swift`) — I-2; measure scan time on real logs
- [x] T3 Standalone tests `tools/tests/agent-usage-tests.sh` (levels, headline, windows, months,
      pace, precedence, parsers on real response shapes, dedupe/deltas)
- [x] T4 Tracker (credentials, fetch, scheduler, backoff, FSEvents, cache, staleness) — I-4, I-5
- [x] T5 Chips + popover + limit form; wire into `ModuleExplorerView` header — I-6, I-7
- [x] T6 Settings visibility toggles (DDESettingsView)
- [x] T7 pbxproj entries; `./bump-version.sh minor`; Debug build
- [x] T8 Verify: tests, harness run of tracker against real data (official + local), launch the
      Debug build (not the installed app) and look at the header/popover
- [x] T9 Feature docs: DEC-017..019 for the answers above; review section here

### Review (2026-09-26)
- Files: `Models/AgentUsage.swift`, `Models/AgentUsageLogs.swift`, `Models/AgentUsageTracker.swift`,
  `Views/AgentUsageViews.swift`; wired in `ModuleExplorerView` (header) and `DDESettingsView`
  (show/hide per agent). Decisions from the user's answers: DEC-017..019 in the feature folder.
- Tests: `tools/tests/agent-usage-tests.sh` — 83 checks (levels at 80/95 boundaries, headline and
  tie-break, pace, 5h/weekly/monthly windows incl. Jan 31 clamping and a future anchor, state
  precedence, both official response shapes, log dedupe/deltas/incremental reads/partial lines,
  changed format → error, missing logs → error).
- Live harness (real tracker, real credentials, real logs): Claude official 3 windows (5h headline),
  Codex official weekly; local figures per window after the 7-day rescan. Fake home
  (`CFFIXED_USER_HOME`): expired Claude token → signed-out hint without any request; Codex 401 →
  hint; broken Claude logs → "usage unavailable"; Codex no limit → today's tokens; 1000-token/5h
  limit → estimated 90%, 100 left; clearing → back to no limit.
- Rendering: header (wide/narrow), both popovers and the limit form rendered offscreen with
  ImageRenderer from live data. Found and fixed: local all-model tokens shown under the
  model-scoped "Weekly (Fable)" window → no local figure for scoped windows.
- Perf: first 7-day Claude scan ≈ 6 s off-main (650 MB), rescans ≈ 30 ms; peak memory 92 MB
  (was 1.18 GB before per-chunk reading + autorelease pools).
- Not verified: the chips inside the running app window (an isolated Debug copy with its own
  bundle id never opened its main window); backoff after 429/5xx was not triggered live.
- Version 2.14.0.

## Done 30: Bug investigation — questions for a bug report in the Feature tab (option B, 2026-09-26, 2.13.0)

User: after New Bug the Feature tab does not open, nothing investigates the bug or asks questions.
Today a bug is a one-shot report (`FeatureIntake.newBug`) that only lists "Missing information".
Option B (user's choice): the bug stays ONE file in docs/bugs/; the missing information becomes
questions answered in the Feature tab, and each answer refines the report.

### Design
- **Storage (one file, no workspace):** questions live in the report's front matter as
  `questions:` — list of maps `id` (BQ-1…), `text`, `why`, `options` [{label, text}], `status`
  (open / answered / skipped), `answer`. The body gets a `## Clarifications` section: one
  "**BQ-n** question — answer" entry per answer (the readable history). "Missing information"
  stays as the AI's current list.
- **Intake:** the `intake:bug` schema adds `questions` (0–3, the most important of `missing`,
  with 2–4 options where the answer is a choice, none when it is free text). Written into the
  front matter. `intakeFinished` for a bug also shows the right panel and selects the Feature tab.
- **Which panel:** the Feature tab shows a Bug panel whenever the active editor tab is a file in
  docs/bugs/ (same rule as `openObject`), otherwise the feature as today. No new "active bug"
  state; clicking a bug in Issues → Bugs opens the file and the panel follows.
- **Bug panel:** header (BUG-id, title, severity, status, GitHub issue link); open question cards
  (Choose option / own answer / "I don't know" = skip); answered questions (collapsed);
  "Investigate" button — for a report with no open questions (hand-written or made before this
  change) it runs the analysis on the file and asks the next questions; spinner while running;
  errors in the panel as for features.
- **Answer = one AI call** (`FeatureAssistant.answerBug(url, question:, answer:)`, key
  `bug:<BUG-id>`): input = the report + all answers so far + this answer; the AI may read the
  project (read-only) again. Output = the same fields as the intake (summary, steps, expected,
  actual, environment, suspected, causes, missing, severity) + `has_question`/`question` (next
  one, max 1) — the report sections are rewritten, "Original description", "Attachments" and
  "Clarifications" are kept, the question is marked answered. Discovery ends when nothing needed
  for reproduction and locating the cause is missing (no endless questions; cap: 8 answered).
- **Language:** questions, options, "why" in the AI language (existing system prompt);
  the report text stays English (as for features).
- **GitHub:** nothing automatic; "Post update to #n" was not approved (not built).
- **Fix with AI** (approved 2026-09-26): Bug panel button → status `fixing` and the report to the
  Terminal assistant ("/goal fix the bug in <path>: reproduce, find the root cause, fix, verify");
  a status menu (open / fixing / fixed / closed) closes the loop by hand.
- The Feature tab is shown when the project has docs/features OR docs/bugs (was features only).
- An answer is written to the file before the AI call, so a failed call loses nothing.

### Tasks
- [x] T1 `BugReport` model: parse `questions` from the front matter (`BugQuestion` struct),
      open/answered accessors; keep hand-written reports without `questions` working
- [x] T2 Report writing shared by intake and answers: one function builds the body from the AI
      object, preserving Original description / Attachments / Clarifications; front matter
      re-written without losing other keys (refuse when `isLossless` is false, as elsewhere)
- [x] T3 `newBug`: `questions` in the schema and prompt, saved to the front matter
- [x] T4 `FeatureAssistant.investigateBug(url)` (first questions for an existing report) and
      `answerBug(url, question:, answer:)` / `skipBugQuestion`; store reloads `bugs` after writes
- [x] T5 `intakeFinished`: bug → open the report, show the right panel on the Feature tab
- [x] T6 `BugPanelView` in FeaturePanelView.swift (or its own file) reusing `card`, `SmallButton`,
      `Working`, `FlowButtons`; FeaturePanelView switches to it for docs/bugs files
- [x] T7 IntakeSheet footer text for bugs: mention that questions follow in the Feature tab
- [x] T8 Version: `./bump-version.sh minor` (2.13.0); Debug build
- [x] T10 Fix with AI + status menu (`FeatureStore.updateBug`, `WorkspaceManager.fixBugWithAI`)
- [x] T9 Verify: harness (app sources + test main) on a temp git project with real AI —
      New Bug with a vague description → questions in the front matter; answer one → report
      sections refined, Clarifications entry, next question; skip; Investigate on a
      hand-written report; a report with non-lossless front matter is refused, not damaged.
      Then Boris checks the panel in the running app (not restarted by me).
### Review
- Harness (app sources + test main, real Claude calls) on a temp git project with a CSV export that
  drops the last partial batch: two runs, all checks pass — intake asked 3 questions (options for
  choices, none for free text); an answer recorded before the AI call, sections rewritten, one
  Original description, settled questions closed (a Russian answer mentioning macOS settled two),
  next question BQ-4 after the earlier ones; "I don't know" → skipped; a hand-written report
  (no front matter, own "## Notes") got front matter and kept its text under Original description;
  front matter with a comment is refused and left byte-identical.
- First run: after a Russian answer the report itself came back in Russian. The system prompt lists
  spec items to keep in English but not bug reports; the bug prompts now say it explicitly. Rerun
  with a Russian answer: Summary in English.
- Not built: "Post update to #n" (not approved). Not checked by hand yet: the Bug panel, Fix with AI
  and the status menu in the running app; the Feature tab now also shows for docs/bugs-only projects.


## Done 29: Lifecycle event log & cycle-time analytics (docs/features/lifecycle-event-log-cycle-time-analytics, epic #10, 2026-09-26, 2.12.0)
- [x] I-1 Event store: `LifecycleLog` (shared by all windows), append-only JSONL in ~/Library/Application Support/MarkView/lifecycle-events.jsonl; key = project root path + feature slug; nine stages only; no edit/delete API; damaged lines and unknown stages skipped on read; read and writes serialized on one queue
- [x] I-2 Actor = git user.name of the project, else the macOS user; `LifecycleModels` in UserDefaults (most recent first, trimmed, case-insensitive dedup, new names added)
- [x] I-3 Automatic: idea created in `createFeature`; questions resolved (open ≥1 → 0) and spec ready (status → ready) found by diffing every reload (app writes and external edits); first load only sets the baseline (no backfill); restart does not count; one store per project records (several windows)
- [x] I-4 Header "Lifecycle" row → "Mark stage" (six manual stages) → confirmation sheet: feature, stage, time now, actor, model (required for implementation started, prefilled for finished, menu of known models), note ≤ 500, warnings for a repeat and for later stages already recorded
- [x] I-5 `LifecycleAnalytics` (Foundation only): adjacent steps, earliest start → latest end, no bridging, negative = inconsistent, total idea→verified, median/mean/count, model of the start event, "2d 3h 15m"; `tools/tests/lifecycle-tests.sh` (38 checks)
- [x] I-6 Timeline in the collapsible Lifecycle section: events oldest first (time, stage, actor, model, auto/manual, note), 8 steps with duration / — / inconsistent, total
- [x] I-7 ⋯ menu "Project Cycle Time…" sheet: step, median, mean, features; implementation step broken down by model; current project, existing features only
- [x] Version 2.12.0, Debug build succeeds
### Review
- Harness (app sources compiled with a test main, `CFFIXED_USER_HOME` so the real log is untouched) on a temp git repo: 18 checks — actor from git, idea created, questions resolved only on the last close (and again after reopen + close), spec ready on entering ready only, an on-disk edit recorded once with two stores on the same folder, restart records nothing, manual automatic stage refused, model/note trimmed and capped, no backfill, file lines = events. A second launch reloads the file and skips a garbage line and an unknown stage.
- Known limits: transitions that happen while MarkView is closed are not recorded (the next launch only sets the baseline); with two windows on one folder, a restart done in the non-recording window can record a "questions resolved"; timestamps are stored to the second.
- Not checked by hand yet: the Lifecycle row, the Mark stage sheet and the Project Cycle Time sheet in the running app.

## Done 28: Findings decided by AI, outdated check, restart and delete a feature (2026-09-26, 2.11.0)
- [x] Finding card: "Decide for me" — the AI picks the resolution (`chosen`, AI language), decision proposed ("Chosen by AI"), finding resolved (`answered_by: ai`)
- [x] Review: "Decide all for me (N)" — open findings resolved by the AI, 8 per call, progress "k of N done"; shared `closeFinding`
- [x] Header: labelled "Clean up" button (the trash icon was not found)
- [x] Cleanup sheet: "Find outdated (AI)" — one call compares decisions and open findings with the current requirements; outdated decisions → superseded (+ superseded_by, outdated_reason), findings → dismissed (dismissed_reason); reasons shown in the lists
- [x] Header ⋯ menu: Restart Feature… (trash requirements, questions, decisions, findings, research, plan, discussion; keep overview and references; status idea, understanding reset, discovery starts) and Delete Feature… (folder to the Trash; GitHub issues named as staying open); both off once implementing/implemented/verified
### Review
- Why "cleanup does nothing with decisions/findings": the earlier cleanup did trash 73 questions and 26 closed findings; the 99 decisions were all accepted and 36 findings open, which the rules keep. After consolidation 23 findings pointed at REQ-275 — hence the AI outdated check.
- Real AI on a copy: markOutdated → 7 decisions superseded, 0 findings (all judged still relevant); decideAllFindings → 32 of 36 resolved within the run, Russian resolutions, proposed decisions.
- Harness on a copy: restart → only overview + SRC-001 left, status idea, 11 open dimensions, issue link kept; delete → folder trashed; both refused for status implementing.

## Done 27: Stop the endless questions — "Decide for me" and "Decide the rest and finish" (2026-09-26, 2.10.0)
- [x] Question card: "Decide for me" — the AI picks the best answer itself (`chosen`, in the AI language), writes the decision as `proposed` ("Chosen by AI"), refines requirements and asks the next question in the same call; the question gets `answered_by: ai`
- [x] Explore: "Decide the rest and finish" — one call makes the remaining product-owner decisions (≤ 8, proposed, "Decided by AI"), answers the open questions they settle, defers the rest, every open dimension ends known/n/a (forced), questions_left 0; result card lists the decisions
- [x] Shared `applyRequirementChanges` for answers and AI decisions (no duplicate source ids)
- [x] Research is only started by the user: question card "Research this", Review "Research gaps", the context panel of a question, the ✦ editor menu
### Review
- Real AI calls on a copy of the feature (two dimensions reopened): exploreNext asked Q-075; "Decide for me" → answered, DEC-100 proposed, dimensions closed; decideRest → 3 proposed decisions, understood, 0 open questions.
- First run: `chosen` came in English; added it to the conversation-language list in the system prompt; rerun → Russian answer, English decision text.

## Done 26: Feature cleanup — outdated requirements, answered questions, closed findings, cancelled decisions (2026-09-26, 2.9.0)
- [x] Categories (user's choice): superseded/rejected requirements; answered questions whose answer is in an accepted/proposed decision (resolved_by); resolved/dismissed findings and open ones whose requirements are all gone; rejected/superseded decisions
- [x] Trash button in the feature header → "Clean up" sheet: per-category toggle, count, Show list (id, title, status), "Move N to Trash", spinner, result
- [x] "N outdated requirements" banner opens the same sheet with only requirements chosen
- [x] `FeatureStore.cleanUp(slug, ids:)` replaces `deleteOutdatedRequirements`: list links and resolved_by/superseded_by move to the replacement (chains followed, never onto an object deleted in the same run, no self-links) or are removed; plan issues' requirements and decisions too
### Review
- Harness on a copy of feature-lifecycle-events-timing-analytics (after the 2.8.0 cleanup): 73 questions + 25 findings trashed (241 → 143 objects), 98 decisions + 2 requirements relinked (sources Q-… removed), 0 dangling or self links, no candidates left.
- Body text that mentions deleted ids (e.g. "(Q-003)" in a decision's context) is left as written.

## Done 25: Delete outdated requirements after consolidation (2026-09-26, 2.8.0)
- [x] Review stage: "N outdated requirements" banner (merged / rejected counts) with Delete… and a confirmation
- [x] `FeatureStore.deleteOutdatedRequirements`: superseded and rejected requirement files go to the Trash
- [x] Links to them (depends_on, decisions, sources, produces, requirements, … and the plan's issues) move to the requirement they were merged into (following chains), or are removed; no self-links
- [x] Plan rewritten only when one of its issues pointed at a deleted requirement (savePlan regenerates the body)
### Review
- Harness (app sources compiled with a test main) on a copy of feature-lifecycle-events-timing-analytics: 287 → 10 requirements, 277 files trashed, 162 decisions/questions/findings relinked (e.g. Q-001 produces REQ-076 → REQ-280 through REQ-248), 0 dangling links, merged requirements' sources emptied instead of pointing at themselves.
- First run found the self-link bug (sources: [REQ-286] on REQ-286); fixed and re-run.

## Done 24: Discovery stops when the feature is understood; the spec stays small (2026-09-26)

User: a small feature (timing events) grew to 69 questions, 81 decisions, 241 requirements.
Cause: no stop rule (the AI asked while anything was unclear, incl. implementation details) and
every answer added up to 4 new requirements instead of refining existing ones.
- [x] Completeness is defined: a dimension is known when every product-owner decision about it
      is made; implementation details and review edge cases never make it partial. Every question
      names the dimension it clarifies and must target an open one. All dimensions known / n/a →
      discovery ends ("Feature understood → Review"); no AI call. No question budget (user).
- [x] Scope rule: never grow the feature; no implementation-detail questions.
- [x] Answers update existing requirements (requirement_updates) and add at most 2 new ones.
- [x] Consolidate requirements (Review, shown above 30): the AI merges into ≤30; merged files stay
      as status superseded with superseded_by (dropped ones rejected); one reload for all writes.
      Superseded requirements are left out of context, readiness, review and planning.
- [x] Progress line: understood N/11 · answered · requirements; "Still to clarify: …".
- [x] Fixed: the next question's card showed the previous answer and "Try again" (SwiftUI reused
      the card's state) — each question has its own card now.
- [x] Version 2.6.2 → 2.7.0. Built; not installed.

## Done 23: Explore feedback — clearer understanding, fewer waits, the user's language (2026-09-26)

User testing a feature.
- [x] Understanding is a list: each dimension with its state as a word and colour, the AI's note
      (what is known / missing), a legend; states still changeable by click.
- [x] Progress: "N of 11 clear · ≈N questions left" (the AI's estimate, `questions_left`) and
      "Enough questions → Review".
- [x] One AI call per answer: the decision, requirements, understanding and the next question come
      together (checked: 15 s instead of ~35 s for two calls).
- [x] Language: conversation (questions, options, notes, replies, suggestions) in the AI language
      setting; the specification (requirements, decisions, findings, research) stays English
      (checked with Russian: Russian question, English REQ/DEC).
- [x] A chosen option / typed answer shows at once ("Answer taken — updating…"); steps are marked
      running before their prompt is built.
- [x] Version 2.5.1 → 2.6.0. Built; not installed.
- [x] 2.6.1: Review had no feedback either — every AI step (resolution options, resolve, pros/cons,
      more options, research, criteria, discussion, plan) is marked running at the click; a
      finding shows the chosen resolution with "Recording the decision…", Discuss says where the
      reply comes, the panel scrolls to a new answer.
- [x] 2.6.2: still no spinner on Resolve — the cards watched the feature store, not the AI engine,
      so SwiftUI never redrew them while a step ran. The engine is now an environment object every
      Feature card watches. Also: PR row actions (checkout, approve, comment, merge, close) show a
      spinner in the row; "New … from #n / PR" opens the sheet at once and loads the text there.

## Done 22: Tab bar — overflow menu, reorder by dragging, wheel scrolling (2026-09-26)

- [x] ▾ menu at the right of the tab bar lists every open tab (icon, ✓ active, • modified),
      also those scrolled out of sight; Close All.
- [x] Tabs reorder by drag and drop (a blue line marks the drop place; after the last tab =
      at the end); the active tab stays active.
- [x] The row scrolls with the plain mouse wheel (it only scrolled with sideways trackpad
      swipes); the active tab is scrolled into view when it changes.
- [x] Icons by kind: file, code, X-Ray, PR X-Ray, terminal, GitHub run / issue, image.
- [x] Version 2.4.1 → 2.5.0. Built; not installed. Not tried in the live window.
- [x] 2.5.1: voice recording broke when switching tabs — the recorder lived in the microphone
      button's view and died with it; now the terminal session (and the feature engine, for voice
      notes) owns it; each recording has its own temporary file, deleted after transcription.

## Done 21: "I Need to Understand" is an X-Ray search (2026-09-26)

User: the old one was slow and duplicated asking in the terminal; it should X-Ray the project.

- [x] "I Need to Understand" (⊞, from a document) runs the X-Ray ⚡ search at once: related parts
      marked in every view, the answer and its places on the right. The slow research call and
      its automatic docs/research file are gone.
- [x] Code viewer "⚡ <question>" lens: the search's places inside the open file, highlighted,
      each with what it does for the question; a file opened from the answer starts on it.
- [x] "Save to docs/research" in the answer panel (user: the result may be kept): the answer and
      every place as `path:line` links, no new AI call.
- [x] Version 2.3.0 → 2.4.0. Built; not installed.
- [x] 2.4.1: X-Ray breadcrumbs did not move the details panel — the top crumb ("Pull request",
      "Logical"…) kept the previous selection; now it clears it (overview / PR panel), and a
      level crumb selects that level and drops a selected arrow.

## Done 20: Issues list, hand-written features, dot files, .gitignore (2026-09-26)

User feedback on 2.2.0.

- [x] Left panel: "Issues" tab (only when docs/features or docs/bugs exists) with Features and
      Bugs; each with its GitHub links (#n → the issue tab, or the browser without the
      integration). A feature opens its navigator ("‹ Issues" back), incl. its Documents.
- [x] Hand-written features (any folder in docs/features: requirements.md, design.md, …) are
      listed and readable (title from the first heading, issue/PR/epic references found in the
      text); AI steps read their documents; the first AI step adds an overview.md (their own
      files untouched). Checked on broker-fabric: all 37 features, and vivaa's BUG-001 (#253).
- [x] Right panel: the Feature tab only when docs/features exists (a plain Markdown viewer
      shows no feature UI).
- [x] File tree: dot files and folders shown (.claude, .github, .gitignore, .env…) except .git,
      .dde, .DS_Store; they open as text; every row shows its modification date; "Add to
      .gitignore" (files, folders) and "New File (Ignored by Git)…". Dot files stay out of code
      search (secrets never reach the AI).
- [x] Version 2.2.0 → 2.3.0. Built; not installed (the user installs when they allow).

## Done 19: X-Ray explains links and answers questions; New from GitHub / documents (2026-09-26)

- [x] Click an arrow → details panel: source → target, the code lines behind the link (the
      source's files naming the target's files), and the AI's explanation (why, through which
      code, expected or a smell, what breaks) — streamed, "Explain again".
- [x] ⚡ question → full answer in the details panel (direct answer, parts and why, risks) and
      the flow step by step with clickable places; related logical components and deployment
      nodes marked too (deployment view shows the search now: named nodes and nodes running
      code that matters). "Only flagged" unchanged.
- [x] New Feature / New Bug from a GitHub issue (list context menu, issue tab "New from It")
      and from a PR (⋯ menu); New … from a document (file tree context menu, ⊞ → "From the
      open document").
- [x] Implement with AI (file tree, ⊞, Build stage of a feature): the document goes to the
      assistant in the Terminal tab — `/goal implement <path> — ask any question if you are
      in doubt` for Claude Code, a plain instruction for the others.
- [x] Storage moved under docs/ (user): docs/features/, docs/bugs/, docs/research/.
- [x] Version 2.1.0 → 2.2.0.

### Review
- Search request checked live on MarkView ("How does the Git tab show Actions runs and logs?"):
  43 s, answer with `path:line` references, components [git, ai], deployment [app, gh], 8 steps,
  19 places parsed. Edge explanation and the live X-Ray panels not clicked through in the window.

## Done 18: Feature workspaces — discovery, review, resolve, build (2026-09-26)

Source: docs/plans/documents-actions.md (whole document). User decisions: everything in the doc;
reuse the three panels; one Markdown file per object; in-app structured AI; IDs per feature;
one release; generated specs always in English; default owner = git user.name.

### Storage (Markdown is the source of truth)
`docs/features/<slug>/` — `overview.md` (type feature: title, status, understanding map, idea) and
one file per object, YAML front matter + Markdown body:
- `requirements/REQ-001.md` — status draft|review|approved|rejected, req_type, depends_on,
  decisions, sources, issues, provenance; body: statement + `## Acceptance Criteria` (- [ ]).
- `questions/Q-001.md` — status open|answered|deferred, q_type, blocking, owner, options,
  answer, resolved_by.
- `decisions/DEC-001.md` — status proposed|accepted|rejected|superseded; body: Context,
  Alternatives, Decision, Reason, Consequences; sources, produces.
- `findings/F-001.md` — severity blocker|high|medium|low, category, perspectives, status
  open|discussing|resolved|accepted-risk|dismissed, document + quote, interpretations.
- `research/R-001.md` — topic, claims with kind project-fact|external-fact|ai-inference|
  user-decision|open-assumption and sources.
- `references/SRC-001.md` (+ the ingested file next to it) — role, origin, extracted facts
  (pending|accepted|rejected).
- `implementation/plan.md` — issues (title, summary, requirements, decisions, github).
Every object: id, type, feature, created, provenance, owner where relevant.

### UI (three panels)
- Left panel: `Files | Feature`. Feature navigator: feature picker + New Feature, status,
  sections Overview, Requirements, Questions, Decisions, Findings, Research, References,
  Implementation, History (git log) — rows open the Markdown file.
- Right panel: new `Feature` tab — stage bar EXPLORE → REVIEW → RESOLVE → BUILD, readiness
  (explicit conditions), and the stage view:
  - Explore: idea, Understanding checklist, next prioritized question with options
    (Choose A…, Suggest another, Research this, Show pros/cons, Skip, free answer);
    ingestion (drop files, URL, GitHub issue, voice note) → facts to Accept/Reject/Edit/Discuss;
    discussion with "Save as Decision?" detection.
  - Review: run review (perspectives unified) → dashboard by category → finding cards
    (Resolve, Discuss, Edit requirement, Accept risk, Dismiss).
  - Resolve: Resolution Center — blocking questions, conflicts with AI options, findings,
    assumptions, research gaps.
  - Build: AI decomposition into issues (drag requirements between issues), coverage,
    approve → GitHub issues with requirement/decision references; PR links.
  - Object context (a REQ/Q/DEC/F file open in the editor): trace up/down and, for decisions,
    change impact (requirements, issues, documents, code paths).
- Editor selection → ✦ menu: Ask AI, Challenge, Expand, Research, Find Edge Cases, Find
  Contradictions, Find Related Documentation, Explain, Generate Diagram, Turn Into
  Requirement, Create Decision, Create Question — results in the Feature tab.

### Engine
- `FrontMatter` (YAML subset: scalars, lists, list of maps, nested maps).
- `FeatureStore` per window: load/watch features, create/update objects, next IDs, graph
  (contains, resolved-by, produces, depends-on, implemented-by), readiness, impact.
- `FeatureAI`: CLICompletion with JSON schemas, read-only project access, web tools for
  research (Claude WebSearch/WebFetch, Codex --search); context from the graph (§31).

### Plan
- [x] FrontMatter (YAML subset) — round-trip harness: scalars, lists, list of maps, nested maps,
      quoting, edits.
- [x] Feature models, store, IDs, graph, readiness (only measurable conditions count), impact,
      history (git log), provenance on every object.
- [x] FeatureAI actions: explore (understanding + next question with options), answer →
      decision + requirements, more options, pros/cons, skip, research (web), review (unified
      perspectives), acceptance criteria, resolution options + resolve, contextual actions,
      chat with decision detection, decomposition, GitHub issues + epic, PR links, PR files.
- [x] Left panel Files | Feature navigator; New Feature form; status; history.
- [x] Right panel Feature tab: stage bar, readiness conditions, object context (trace, impact,
      history), results, discussion; Explore / Review / Resolve / Build views.
- [x] Editor selection ✦ menu (JS + bridge both sides) → Feature tab.
- [x] Ingestion: files (PDF text, images for the assistant, audio via Whisper), URL, GitHub
      issue, notes, voice notes; facts Accept/Reject/Edit/Discuss.
- [x] Build: decomposition, drag requirements between issues, coverage, GitHub issues with
      requirement/decision references, epic, PR links.
- [x] "New" intake (user, mid-work): toolbar ⊞ → New Feature (feature files + GitHub issue),
      New Bug (bugs/BUG-nnn with repro + suspected code + GitHub issue, no branch), I Need to
      Understand (research/RES-nnn answer, opened).
- [x] Code review (13 findings; 12 fixed, 1 not a bug — `codex --search exec` does search, seen
      as web_search events): stale background reloads dropped (generation counter), new files
      never overwrite (`withoutOverwriting`, ids above file names), updates re-read the file
      first and refuse lossy YAML, front matter: CRLF, apostrophes in lists, one-pass unescape,
      block scalars, comments detected; PDF/URL reading off the main thread; one feature
      reloaded per write; source id reserved before copying; answers dropped when the folder
      changed; distinct job keys, "already running" shown; trace list ids; bug report written
      before its GitHub issue; issue creation stops instead of duplicating.
- [x] From a GitHub issue (user, mid-work): New Feature / New Bug can start from an open issue
      (text + comments as material); the result links that issue instead of filing a new one;
      for a bug, optionally post the analysis as a comment.
- [x] Version 2.0.2 → 2.1.0; regression run of the engine after the fixes.

### Review
- Engine checked end to end with the real assistant (Claude) on a scratch repo: create →
  explore (10 s, blocking question with options) → answer A (DEC-001 + 3 REQs, links both
  ways) → review (22 s, 9 findings incl. a contradiction found in the project docs) → plan
  (4 issues covering every requirement) → resolution options + resolve (DEC-002, finding
  closed) → acceptance criteria → research with web (claims with kinds) → ingest notes and a
  URL (roles, facts) → challenge / create question / diagram → chat with decision detected.
  Intake: new feature 35 s, new bug 19 s (found the cause in export.js), understand 31 s.
- Fixed while testing: readiness counted empty conditions (an empty feature showed 43 %);
  impact listed requirements twice.
- UI: debug build launched separately — Files | Feature and the Feature tab present, no crash.
  Stage views not clicked through in the live window; GitHub issue creation not exercised.

## Done 17: Compact, console-like UI; toolbar and AI menus cleaned up (2026-09-26)

User's decisions, plus an audit of which AI features work (code paths traced end to end).

- [x] Toolbar, icons only: left and right panel toggles side by side (leading edge); X-Ray,
      assistant/model, AI Tools, theme. Removed from it: AI language (already in Settings),
      New Markdown File (file tree has it), New Graph Diagram (moved to the file tree),
      Generate Documentation (removed), Export PDF (File menu, ⌘E, already there).
- [x] File tree: "New graph diagram here" button and "New Graph Diagram…" in both context
      menus; the diagram is written into that folder.
- [x] AI Tools menu: Diagrams (6) + Analysis: Constructive Critic, Deep Research, Codebase
      Audit, Code Structure Map, Recursive Insight — all traced working (prompt to the AI
      terminal; Insight's pipeline complete). "Generate Full Documentation" removed with
      Generate Documentation (same job).
- [x] Fixed on the way: Data Flow diagram had no entry in the Graph Creator (fell back to
      architecture); Critic from the toolbar wrote `review-x.md.md`; mermaid "AI Edit" never
      told the assistant which file to save.
- [x] Editor toolbar: the duplicate "⟁ AI Tools ▾" dropdown removed (and its `aiTool` bridge
      message on both sides); "Insert Mermaid" kept as a button; RU / EN / ? (translate,
      explain — working, CLICompletion) kept.
- [x] Density: markdown line height 1.5, tighter heading/paragraph margins, editor padding
      10/18, viewer 14px up to 1100px wide; formatting bar 22px; tab bar 24px, status bar
      20px; 11pt rows in the file tree and contents; smaller segmented tabs.
- [x] Version 1.34.2 → 2.0.0 (features removed).
- [x] 2.0.1: new app icon for 2.0 — dark console window, X-Ray viewfinder brackets, monospace
      "M" with a green cursor (drawn with CoreGraphics at 1024 px, all sizes from it; legible
      at 32 px).
- [x] 2.0.2: 2.0.x crashed at launch — `AIToolsMenu` in the toolbar read `WorkspaceManager` as
      an environment object the toolbar does not get; now passed in.

### Review
- Build clean; JS syntax checked. Not checked in the live app window (needs an install).
- Known, left as is: OpenAI key in Settings only serves Whisper voice input (embeddings unused).

## Done 16: Issue text as on GitHub, reliable AI prompts, Terminal tab (2026-09-26)

User feedback on 1.33.0.

- [x] Issue tab: body and comments in GitHub's own rendering (`body_html`, full+json):
      markdown, tables, code, task lists, details, images (signed links, private repos too),
      avatars; WKWebView with scripts off, links open in the browser, app-like dark/light style.
- [x] Prompts to the AI terminal were lost in a new terminal (fixed 4 s wait while
      `claude update && claude` was still starting → text went to the shell). A paste now waits
      until the startup command was typed and the output has been quiet for 2 s (max 45 s).
      Affects "Start with AI", "Fix it", "Fix with AI" and every other prompt button.
- [x] Right panel: Contents | Search | Git | Terminal; the "Toggle AI Panel" toolbar button and
      the panel swap are gone; ⌘3 (View → Terminal) opens the Terminal tab.
- [x] Version 1.33.0 → 1.34.0.
- [x] 1.34.1: Explain on a file opened from the PR X-Ray did nothing — the pull request's cached
      copy was explained under its absolute cache path while the notes looked up the project
      path (also broke explainPR there); one `codePath(for:)` everywhere, notes kept in the
      project's .dde; the Explain button leaves the Pull request lens for the file's notes.
- [x] 1.34.2: "Initialize Git Repo" in a project with git — opening a markdown file from the PR
      X-Ray (a PR's cached copy, or a removed file's old version) outside the folder turned the
      window into a single-file workspace on the cache folder (no git, database dropped,
      terminals stopped). PR cache copies now count as part of the open project.

### Review
- Issue page rendered offscreen from cli/cli#14528 (17 images, 2 comments) and checked on a
  snapshot: headings, tables, code blocks, details, images load.
- Not checked in the live app: the new Terminal tab and the prompt timing with a real Claude start.

## Done 15: Full GitHub integration (2026-09-26)

Approved by the user (UI proposal + defaults to questions 1–12, one release, minor bump).
Everything goes through the signed-in `gh` CLI (no tokens stored by MarkView).

### Spec
- **Git tab** (right panel, Contents | Search | Git) gets sections
  `Changes | PRs | Issues | Actions`; Changes = today's view. Branch header shows the current
  branch's CI status dot. Repo picker when both `origin` and a fork `upstream` exist.
- **PRs**: filters Open/Closed/Merged × All/Mine/Review requested, text filter; row = number,
  title, author, head → base, age, checks, comments; buttons ✦ Review, Checkout, ⋯ (Open on
  GitHub, Copy link, Approve, Request changes, Comment, Merge merge/squash/rebase, Close);
  New PR (current branch, pushes first).
- **Review** → PR X-Ray for that PR and starts "Review with AI" at once
  (Settings toggle `settings.github.autoReview`, default on).
- **PR X-Ray details panel**: PR header (state, checks, review decision) with Approve /
  Request changes / Merge ▾ / Open on GitHub; every finding has ✦ Fix it, ✦ Explain (inline,
  streamed), 💬 Comment on PR (line comment), ＋ Issue, ✕ Dismiss; "Fix all" next to the task list.
  Fix it on a GitHub PR checks the PR branch out first (`gh pr checkout`), refusing when the
  working tree has changes; then the prompt goes to the AI terminal.
- **Actions**: list of runs (workflow/branch filter, status, duration, age; live), ▶ Run
  workflow… (workflow_dispatch inputs form), workflow ⋯ → edit its .yml. A run opens as an
  editor tab: header actions Re-run failed / Re-run all / Cancel / Open on GitHub / ✦ Explain
  failure / ✦ Fix with AI; jobs list; steps with durations; log per step with search and
  error highlighting. Logs exist per job once that job has finished (GitHub limitation);
  running jobs show live step progress.
- **Issues**: filters Open/Closed × All/Assigned to me/Created by me, text filter; New issue;
  an issue opens as an editor tab: markdown body, comments, comment box, Close/Reopen, labels,
  assignees, ✦ Start with AI (branch `issue-<n>-<slug>` + prompt to the AI terminal).
- **Opt-in** (user, mid-work): Settings switch `settings.github.enabled`, off by default;
  folders only (never a single file). Off → no `gh`, no polling, Git tab unchanged.
- **Polling**: runs every 30 s while one is active, else every 5 min (Settings); macOS
  notification when a run on one of my branches finishes (Settings toggle).
- **Settings → GitHub** section: account/scopes (gh), Sign in / Switch (Terminal),
  repository, refresh interval, notifications, auto-review.

### Plan
- [x] `Models/GitHubClient.swift`: `gh` runner off the main thread (pipes drained), repo
      detection (origin/upstream), Codable models, all PR/issue/run/workflow commands;
      workflow_dispatch input reader; job log split into steps by the log's own markers.
- [x] `Models/GitHubStore.swift`: @MainActor store per folder — lists, filters, polling,
      notifications, CI status of the current branch; `GitHubContext` for the PR X-Ray.
- [x] `Views/GitHubViews.swift`: PRs, Issues, Actions sections + sheets (new PR / issue,
      review text, dispatch inputs); `GitView` gets the section picker (only when on).
- [x] `TabKind.github(...)`: run and issue tabs drawn over the editor like terminal/image tabs.
- [x] PR X-Ray: PR header (state, checks, decision; Approve / Request changes / Comment /
      Merge ▾ / Close / Open on GitHub), finding actions (Fix it / Explain / Comment on PR /
      + Issue / Dismiss) and Fix all; review on load; `gh` calls use the selected repo.
- [x] Settings GitHub section (switch off by default, account/scopes, sign in, intervals,
      notifications, auto-review).
- [x] pbxproj membership (project.yml globs `MarkView/`), build clean.
- [x] Code review (10 findings, all fixed): PR header buttons were dropped (`action` field
      overwrote the bridge action → `op`); PR actions/header now use the repo the PR was loaded
      from; no app-wide repo state (each window passes its repo; every window observes the
      Settings switch); repo switch clears all its state, tab models keyed by repo; stale async
      results dropped (generation counter); checkout ignores untracked files (.dde); `gh` runs on
      GCD threads with a timeout (60 s, logs 180 s) and refreshes don't overlap; review comment
      per PR, kept across redraws, cleared only on success; transient state not cached; merge
      method / PR op allow-listed in Swift.
- [x] PR X-Ray per user (mid-work): the graph stops at files — no change nodes inside files;
      a click on a file (graph or list) opens it on the Pull request lens, where every change
      has its explanation; removed files are listed and open as they were (base version).
- [x] Version 1.32.0 → 1.33.0.

### Review
- `gh` layer checked with a harness compiled from `GitHubClient.swift` against
  t-boris/MarkView (read-only): repo detection, account + scopes, PR/issue lists with every
  filter, labels, assignees, workflows, runs (+ workflow/branch filters), run, jobs, job log
  split into its 11 steps correctly (first attempt by timestamps was off by one step — the
  log's `##[group]Run` / "Post job cleanup." / "Cleaning up orphan processes" markers are
  exact), remote workflow file, dispatch-input parser on a sample, error text for a missing repo.
- Diff parser: removed file kept (`deleted`, no ranges), new file, and `---`/`+++`-looking lines
  inside a hunk (previously reset the file). `gh` timeout: a hung process ends at the limit.
- Not exercised: write actions against GitHub (approve, merge, comment, issue create, rerun,
  cancel, dispatch) and the UI in the live app window.

## Done 14: GitHub Copilot as a fourth assistant (2026-09-25)

Copilot CLI 1.0.88 speaks ACP too, and filters its tools at the source:
`--available-tools view grep glob` (no shell, edits, web, subagents exist for the model),
`--no-ask-user --disable-builtin-mcps --no-custom-instructions --no-auto-update`,
`--reasoning-effort`. Reads in the working dir run without asking; anything else asks and is
refused. It reports tokens per turn. It prints "Info: Disabled tools: …" as the first answer
chunk — filtered.

- [x] `ClineACP` → `ACPAssistant` (per-assistant profile: arguments, read-only mode, notice
      filter); tokens recorded when reported; answer reset per turn.
- [x] `CLITool.copilot` (`copilot`, `copilot login`, `--model`), menus, Settings probe
      (version ≥ 1, models; signed in when the account lists models), terminal profile.
- [x] Global Copilot CLI upgraded 0.0.348 → 1.0.88 (Homebrew's npm; signature valid).
- [x] Version 1.31.0 → 1.32.0.

### Review
- Harness from the app's code, both assistants: Copilot (GPT-5 mini, 0x) structured answer on
  MarkView 82 s, 15 reads / 17 searches, no shell; tokens 681k/4.5k; plain answer without the
  notice; unknown model → clear error; cancel ok. Cline regression: same checks pass.
- Not checked in the live app window.

## Done 13: Cline as a third assistant (2026-09-25)

Findings (Cline 3.0.65): ACP over stdio works (`cline --acp`): initialize → session/new
(modes plan/act, account models) → session/set_mode plan → session/set_model → session/prompt.
Every tool call asks `session/request_permission` with its kind (read, search, execute, edit…):
allowing only read/search makes a run read-only (verified: reads work, shell and edits refused,
no files created). No usage/cost over ACP. No JSON-schema flag → schema in the prompt, parse,
one repair turn. `--json` rejects stdin prompts; ACP has no such limit. The npm 3.0.65 macOS
binary ships with a broken signature (killed, silent `--version`): ad-hoc re-sign fixes it.

- [x] `CLITool.cline` (Cline, `cline`, login `cline auth`, `-m` in terminals).
- [x] `ClineACP.swift`: ACP client — plan mode, model, read/search-only permissions (none when
      the request has no readable folder), streamed text and activity, cancel/timeout,
      structured answers from the schema in the prompt with one repair turn.
- [x] `CLICompletion.run` routes `.cline` to the ACP client.
- [x] Models: from the account over ACP (cached), "Default" = Cline's configured model.
- [x] Menus (toolbar, Settings, AI terminal), terminal profile, Settings row: probe (version,
      signature problem explained with the fix), login in Terminal.
- [x] Verify: build; real runs through the app's code path (Ask AI, filter, X-Ray part);
      version bump (minor → 1.31.0).

### Review
- Harness compiled from the app's own ClineACP/CLICompletion/AIAssistants against the signed-in
  Cline account (DeepSeek Flash): 318 models listed without a prompt; structured JSON answer
  reading MarkView (Git files — correct), shell attempts refused, repo untouched; 91 s → 46 s after
  telling the model only read/search work; plain streamed answer; cancel → CancellationError;
  unknown model → clear error; Settings probe "3.0.65 · 318 models".
- Global Cline upgraded 1.0.8 → 3.0.65 (Homebrew's npm) and ad-hoc re-signed (bin/.cline too).
- Not checked in the live app window: menus, Settings row and a Cline terminal tab.

## Done 12: AI search inside the X-Ray instead of a separate panel (2026-09-25)

User correction: the search belongs in the X-Ray as a filter, not in its own panel.

- [x] ⚡ quick filter in the X-Ray = AI search (`ArchitectureStore.aiSearch`, `XRaySearch`):
      keyword candidates dashed red in seconds, then the AI reads the project (read-only);
      files/sections it names turn solid red, everything else stays uncoloured.
      Saved filters (＋ New filter…) keep the strong/moderate/weak scale.
- [x] Legend: "<query> — AI search", red = matters, AI summary; "Only flagged" keeps just the
      red parts.
- [x] Right-click → "Explain with AI — everything related" opens the X-Ray with a search for
      that element (definition, calls, callers, data, tests).
- [x] Removed: AI Search toolbar button, left panel, code-viewer "◎ Topic" lens (TopicLens*).
- [x] Version 1.29.0 → 1.30.0.

### Review
- Build passes; X-Ray checked in Chrome on broker-fabric's saved X-Ray with a search result:
  overlay switches to the search, 2 solid + 1 dashed red, 12 uncoloured; Only flagged → 3 red.
- Search engine prompts are the ones verified live on grow-garden (44 / 28 places, all valid).
- Not checked in the live app: a full search run from the X-Ray field (needs a manual run).

## Done 11: Code navigation, AI on a selection, Explain with AI (2026-09-25)

- [x] `CodeNavigation.swift`: definitions and usages of a symbol across the project (one
      `git grep -w` pass, walk fallback), ranked (same file, same language, nearby path);
      back/forward history of jumps.
- [x] Code viewer: ⌘-hover link underline, ⌘-click → definition (on a declaration → usages),
      ⌥⌘-click / right-click menu / F12 / ⇧F12; peek list for several results; ◀ ▶ history.
- [x] AI on a selection: "✦ Ask AI" by the selection → Explain / Find bugs / Improve / own
      question; streamed markdown answer, follow-ups, stop; the AI may read the project.
- [x] Build, check on real projects and in the bundled editor, version bump (minor → 1.29.0).
- [x] Right-click → "✦ Explain with AI — everything related" on any symbol: a topic map seeded
      from its definition and usages (Definition / Calls / Called by / Data / Tests), coloured in
      the code, the rest dimmed. Topic panel renamed "AI Search".

### Review
- Definitions/usages (harness over `CodeNavigator`): MarkView and grow-garden, 0.1–0.6 s per
  lookup; calls no longer count as C definitions; test doubles rank after the real definition.
- Live AI on grow-garden: `identifyPlantFromPhoto` map 28 places / 7 steps, all ranges valid
  (57 s, $0.54); Find bugs on `pickAnalysisSource` — concrete answer with `path:line` (44 s, $0.23).
- Viewer checked in Chrome with the bundled editor: ⌘-click / ⌥⌘-click posts, peek list with
  ↑↓↵, context menu, Ask AI panel (streaming, stop, follow-up history, links, no HTML execution).
- Not checked in the live app window: the full round trip through WKWebView (needs a manual run).

## Done 10: Topic lens — "show me only what is about X" (2026-09-24)

Goal: type a topic ("generating plants from a photo"); see only the project code that is
about it, where exactly it lives (file + line range) and what each place does in the flow
(where the photo comes in, processing, AI call, storage, tests, config…).

- [x] `TopicLens.swift` (Models): `TopicLensStore` on `WorkspaceManager`.
      1. Keyword pass: `FilterSearch.terms` → score every project file (git ls-files) →
         candidate files with their hit lines, shown within seconds (provisional).
      2. AI pass: Claude/Codex with read-only access to the folder, candidates as hints →
         `{summary, steps:[{title, places:[{path,start,end,title,why}]}]}`; places streamed.
      3. Validate paths/lines at the boundary; anchor text per place so line numbers
         follow later edits; cache per topic in `.dde/cache/topics/`; recent topics.
- [x] `TopicLensView` (left sidebar, "Topic" toggle next to the file tree): topic field,
      summary, steps with places; click → open the file at those lines.
- [x] Code viewer lens "◎ Topic": relevant ranges tinted with cards (step, why), the rest
      of the file dimmed; auto-selected when a file is opened from the topic panel.
- [x] Build, manual check on a real project, version bump (minor → 1.28.0).

### Review
- Prompt + schema run on grow-garden ("добавление растения по фото — где получаем фото, как
  распознаём, как тестируем"): 44 places in 11 steps (web/iOS input, API, validation, Gemini
  adapter, wiring/config, backend/web/iOS tests, ADR); every path exists and every range starts
  on the right declaration. 135 s, $1.24 with the default model — keyword candidates show first.
- Code-viewer Topic lens checked in Chrome with the bundled editor: step-coloured places,
  dimmed rest, cards aligned, legend with steps and counts.
- Not yet checked in the live app window: the SwiftUI panel and click-through (needs a manual run).

## Done 9: X-Ray and PR X-Ray round (2026-09-24, 1.2.0 → 1.22.0)

- [x] X-Ray structure from clustering (imports, note links, co-change; `XRayCluster`), AI only names
      clusters; live growth; per-folder X-Ray tabs; deterministic kind tags for hiding.
- [x] AI filters: keyword search first (`FilterSearch`), AI confirms top candidates; quick ⚡ filter.
- [x] Names follow the files' language (measured locally); texts follow the AI-language setting.
- [x] Markdown: formatted notes view, `[[wikilinks]]`, KaTeX in markdown-it; CRLF-safe line counts.
- [x] PR X-Ray: any PR by number, architectural analysis, per-file diff, streamed Q&A.
- [x] File tree: new file/folder here, drag and drop (move, ⌥ copy), last folder reopens.

### Review
- vivaa-platform X-Ray 27 s (was 84 s+), KnowledgeDB 30–41 s (was 119 s); filter colours in ~8 s.
- Verified with real AI runs (vivaa, KnowledgeDB, broker-fabric PRs #81/#122) and in WebKit/Chrome.
- Not covered by automated tests: drag and drop in the live window, gh-only PR flows on other hosts.

## Done 8: X-Ray under a minute (2026-09-24)

- [x] `XRayDigest`: local digest per folder (manifest, README line, declarations,
      files, folder imports), unit selection, parts, draft grouping — no AI.
- [x] Pipeline: draft saved at once → parts in parallel (no tools, low effort, X-Ray
      model) with deployment alongside (configs inlined) → merge into subsystems.
- [x] Answers cached in `.dde/cache/xray` by input hash; digest made deterministic.
- [x] Scanner: per-file complexity in parallel, one regex pass (12.8 s → 4.2 s).

### Review
- vivaa-platform (2,339 files, 292 described folders), Claude Sonnet, effort low:
  draft 3.4 s, first full run 41–62 s (was 87 s with the first version and many
  minutes before), unchanged rerun 3.9 s.

## Done 7: Explain + AI filters for markdown documents (2026-09-24)

Request: documentation should get the same margin panel as code — per-section
AI notes, lenses (Explanation, Importance, Freshness, custom filters), tinted
sections, heat strip, zoom. Chosen: "like code", working in view and edit modes.

### Plan
- [x] Research the markdown editor: modes, scroll containers, source-line mapping,
      heading rendering, pane layout (Explore agent).
- [x] Sections from headings (deterministic, no AI split); AI writes one note per
      section with importance; reuse `CodeExplainStore` (cache, ratings, freshness,
      language, staleness) with a markdown prompt.
- [x] Notes panel beside the document in view and edit modes; section boundaries
      recomputed on edit; notes of changed sections marked stale.
- [x] Tint sections in the document, heat strip, resizable panel, zoom-out
      compaction reused from `markview-code.js` (shared module, not a copy).
- [x] Bridge: route notes for markdown tabs (mirror `routeCodeNotes`).
- [x] Verify in the browser test page (view + edit), real AI on a fixture, build,
      bump minor, deploy.
- [x] Before any commit: delete test files from `Resources/Editor` (notes-test.json,
      code-test.swift.txt, arch-ai-test.json, arch-bf-test.json) — they ship in the app bundle.

## Active 6: Finder "Open With" / folder open does nothing

Symptom: opening a file or folder from Finder launches/activates MarkView but
nothing opens. `~/markview_debug.log` showed `application:open:` → posting
`openInActiveWindow` on every attempt and zero handled opens.

Root cause: SwiftUI shows the window *before* `application(_:open:)`, so the
delegate took the "window visible" branch and posted a fire-and-forget
notification. `ContentView` accepts it only if `hostWindow` is the active window,
but `WindowAccessor` sets `hostWindow` asynchronously — it was still nil, every
window rejected the request, and it was lost.

### Plan
- [x] `MarkViewApp.pendingOpenURLs` queue + `enqueueOpen(_:)`; delegate,
      Finder Services callback and Quick Action poll all enqueue.
- [x] `ContentView.drainPendingOpens` — active window takes the queue on
      request signal, on `hostWindow` attach, and on `didBecomeKey`.
      Removed `consumedOpenRequestIDs` and the single `pendingOpenURL`.
- [x] Build + Finder-style `open -a` checks.

### Review (2026-09-17)
- `xcodebuild` → BUILD SUCCEEDED.
- Cold launch with `.md` → opened (trigger `windowAttached` — the exact race).
- Folder open → `openFolder START`, tree loaded.
- App already running, `.canvas` file → opened in the same process.
- Not exercised: all windows closed while app stays running (same drain path,
  via `didBecomeKey`/`windowAttached`).

## Active 5: Fullscreen viewer for Mermaid diagrams

Request: large mermaid diagrams render too small in the preview (`.mermaid svg`
has `max-width: 100%`); need a way to open a diagram full-screen to inspect
details.

### Solution
Lightbox overlay over the whole window. Hovering a rendered `.mermaid` diagram
shows a "⛶" expand button (double-click on the diagram works too). The overlay
clones the already-rendered SVG at its natural `viewBox` size (vector → crisp at
any zoom) and offers the same interaction scheme as the canvas viewer:
wheel = zoom around cursor, ⇧+wheel = pan, drag = pan, pinch = zoom,
toolbar (Fit / 100% / − / + / ✕), Esc or backdrop click closes.

### Plan
- [x] New module `vendor/js/markview-diagram-viewer.js` — overlay build, pan/zoom
      (mirrors `markview-canvas.js` math), `decorateMermaidDiagrams()`, delegated
      dblclick fallback.
- [x] `markview-render.js` — call `decorateMermaidDiagrams()` after
      `mermaid.run()` resolves (buttons must be injected after SVG replaces the
      div content).
- [x] `index.html` — CSS for expand button + overlay (z-index 1000, above all
      existing chrome ≤ 500); `<script>` tag for the new module. No `project.yml`
      change needed (vendor dir is ditto-copied whole).
- [x] Build with xcodebuild; manual check on TestFiles fixture.

### Review (2026-07-19)
- Implemented as planned; build succeeds, final JS verified inside the built
  app bundle. Verified in Chrome against the served editor (`window.setContent`
  + real DOM events): expand button injected once per diagram (no dupes on
  re-render), fit/wheel-zoom-around-cursor/pan/Esc/backdrop-close all work,
  zoomed SVG text stays crisp.
- Fixed a bug caught during verification: a pan-drag ending on the backdrop
  fires a synthetic `click` there, which closed the overlay mid-interaction.
  Now `dvPanEnd` sets `suppressClick` when the pointer actually moved (>3 px)
  and the backdrop click handler consumes it.
- Pre-existing bug found (NOT fixed, out of scope): `markview-d3-mermaid.js:394`
  throws `ReferenceError: init is not defined` on every page load — it calls
  `init()` (defined in `markview-init.js`) but loads *before* that file.
  Reproduced with and without the new module. Needs a decision: move the
  init-kick into `markview-init.js` or reorder scripts.

## Active 4: Finder "Open Folder" lands in orphaned window (welcome screen shown)

Bug report: "I can't open folder /Users/boris/github.com/vivaa-platform/docs/code-architecture".

### Diagnosis (from ~/markview_debug.log + live app inspection, 2026-07-16)
- The folder itself is fine (normal perms, 10 entries). The app's own log shows
  `openFolder START → Tree loaded: 10 children → openFolder COMPLETE` at 23:49:22Z —
  the open **succeeded internally**, but the only visible window (buildID 45610 =
  process launched 23:46:50Z) still shows the welcome screen with `rootNode == nil`.
- Root cause: `application:open:` only stashes the URL in static
  `MarkViewApp.pendingOpenURL`. Delivery relies on a 0.5 s-delayed closure inside
  *every* ContentView's `.onAppear`. When the Finder open event fires, SwiftUI
  creates/re-attaches more than one ContentView (log shows 2× `onAppear` for 1×
  `WorkspaceManager init`); whichever delayed closure runs first consumes the URL —
  in this case a ContentView whose window was discarded. The surviving visible
  window never sees the URL → user sees "can't open".
- Second latent bug found: `.openInActiveWindow` notification (used by the
  `onOpenURLs` callback and the Finder Quick Action poller `checkFinderOpenRequest`)
  has **no observer anywhere** — that entire delivery path is dead code, so the
  Quick Action route silently does nothing.
- Contributing risk: `ensureWindowExists` (AppDelegate, +0.3 s after activation)
  can race the open event and spawn an extra welcome window via `newWindowForTab:`.

### Fix plan (root-cause: make URL delivery window-aware, not timing-based)
- [ ] 1. ContentView: add `.onReceive(NotificationCenter … .openInActiveWindow)`
      observer — revives the dead path. Handle only if this view's window is key
      (fallback: frontmost visible). Dedup via the `id` already in the payload.
- [ ] 2. AppDelegate `application:open:`: if any visible window exists, post
      `.openInActiveWindow` (same payload shape) instead of relying on the
      onAppear race; keep `pendingOpenURL` **only** for cold launch (no windows yet).
- [ ] 3. ContentView: replace the 0.5 s-delayed `pendingOpenURL` check with a
      `NSWindow.didBecomeKeyNotification`-driven consume (own window became key +
      `rootNode == nil` + URL pending → open). Keeps cold-launch working without
      the multi-instance race.
- [ ] 4. Verify: rebuild; test (a) cold launch via Finder "Open With" on the
      vivaa docs folder, (b) same while app is running showing a welcome window,
      (c) Finder Quick Action file path, (d) Cmd+Shift+O panel unchanged.

### Review
(to be filled after implementation)

## Active 3: .canvas (JSON Canvas) file support

Goal: MarkView opens and renders Obsidian/JSON-Canvas `.canvas` files with full
viewer functionality: pan, zoom (wheel/pinch/buttons/fit), node rendering
(text/file/link/group), edges with arrows+labels, node properties panel,
file-node click-to-open, source view toggle, theme support.

### Plan
- [x] 1. `FileType` (DocumentState.swift): add `canvas` case, `"canvas"` extension, mapping in `from(url:)`
- [x] 2. `FileTreeView.fileIcon`: icon for `.canvas` (`rectangle.3.group`, yellow)
- [x] 3. `ContentView`: accept `.canvas` in drag-drop + Open File panel
- [x] 4. `Info.plist`: Canvas document type + imported UTI `com.markview.jsoncanvas` (conforms to public.json)
- [x] 5. `WebViewBridge`: new JS→Swift message `canvasOpenFile {path}` + delegate method
- [x] 6. `EditorView.Coordinator`: implement delegate; `.canvas` links open in tab
- [x] 7. `WorkspaceManager.openCanvasFileReference(path:)`: resolve vs workspace root, then canvas dir; rejects absolute/`..` paths
- [x] 8. NEW `Resources/Editor/vendor/js/markview-canvas.js` (524 lines) + `vendor/css/markview-canvas.css`
- [x] 9. `markview-structured.js`: branch `fileType === 'canvas'` → canvas renderer
- [x] 10. `index.html`: script tag (after markview-globals.js — wrapper order matters) + css link
- [x] 11. Test fixture `TestFiles/demo.canvas` covering all node/edge variants
- [x] 12. Build BUILD SUCCEEDED; verified live on demo.canvas AND user's real vivaa-platform.canvas (248 nodes · 183 edges)

### Review
- Verified visually in the running app: group/text/file/link nodes, preset+hex colors,
  edges with labels/arrowheads (incl. double-arrow), markdown+code inside text nodes,
  zoom-to-fit (93% demo / 51% real canvas), properties panel (node + edge props, raw
  text block), TOC lists canvas nodes (groups level 1, members level 2) with pan-to-node.
- Interactions: wheel = zoom around cursor (user request mid-review; was pan),
  ⇧+wheel = pan, drag background = pan, pinch = zoom, Fit/100%/−/+ buttons,
  dbl-click background = fit, dbl-click text/group node = zoom-to-node,
  dbl-click file node = open via `canvasOpenFile` (root→canvas-dir resolution),
  dbl-click link node = open in browser, Esc/✕ = deselect, Source ↗ = raw JSON
  (editable, Cmd+S works through existing structured pipeline).
- Fixes found during verification:
  - format-bar popped on selection inside canvas/structured views → gated to
    `state.fileType === 'markdown'` (markview-edit.js, root-cause fix for JSON/XML too).
  - zoom-to-fit ran before WebKit layout on tab-restore → 0×0 viewport clamped to 5%;
    now retries via requestAnimationFrame (bounded 30).
  - `setContent` (markdown path) now restores `state.fileType`/contentEditable —
    pre-existing staleness after viewing any structured file.
  - parse-error view restores body padding/scroll (leaveCanvasView before error render).
  - window-level pan listeners are named functions → addEventListener dedupes across
    re-renders (no listener leak).
- Known scope limits: viewer-first (no node dragging/creation — edit via Source),
  file-node image previews not embedded (sandbox), mermaid inside canvas text nodes
  renders as plain code block.

---

## Active 2: docId = относительный путь + прогресс в футере

### Задача 1 — docId без коллизий (относительный путь от корня)
- [ ] `SemanticDatabase.documentId(for:root:)` — канонический хелпер (POSIX rel-path, fallback на имя).
- [ ] Миграция через `PRAGMA user_version` (=1): очистить documents/modules/struct_relations/entities/claims/fts (FK-каскад чистит blocks/symbols/chunks), реиндекс. **Подтверждено: очистить и реиндекс.**
- [ ] `WorkspaceManager.docId(for:)` → делегат к статике с `rootNode.url`.
- [ ] Producers → хелпер: StructuralIndexer(scanTree/link/extractContentModules), WM(excludeFolder, indexFolderComponents, reindexFile, handleBlocksDelta, analyzeAllFiles), Views(BlockIntelligence, CompilePanel). Single-file (indexSingleFile) — без изменений (имя == rel-path).
- [ ] Резолв ссылок: targetId = rel-path.
- [ ] Обратный поиск в ModuleExplorerView: `root.appendingPathComponent(docId)` + fallback.

### Задача 2 — прогресс индексации в футере
- [ ] runStructuralIndex: stderr дочернего через `Pipe`, парсить `Indexing N/M` → `indexingProgress` (set при спавне, clear в terminationHandler).
- [ ] DiagnosticsBarView: сегмент со спиннером + текстом, видим при `indexingProgress != nil`.

### Задача 3 — фикс зависания (найдено через sample стека)
Реальная причина «висит» — НЕ индексация/WebView/миграция, а `GitClient`:
- [x] `run`/`runWithError` → `nonisolated async` + `Task.detached` (git вне главного потока).
- [x] Читать pipe до `waitUntilExit` (устранён дедлок при выводе git > 64KB pipe-буфера).
- [x] Все вызовы (refresh/commit/push/pull/stage/diff/init) → `await`; `diff` стал async (GitView обновлён).
- [x] Миграция docId: вместо каскадного `DELETE` (вешал main) — **удаление файла БД** при старой
      схеме (user_version) прямо в `init` (O(1), без раздувания). По идее пользователя.

### Verification (проверено)
- [x] Сборка BUILD SUCCEEDED.
- [x] docId = относительные пути: 1038 (с коллизиями) → 1222 уникальных; total==distinct.
- [x] Дерево модулей корректно: 177 модулей, SUM(file_count)=1222, глубина до 5 уровней.
- [x] Миграция: старая БД → файл пересоздан (inode сменился), user_version=1; steady-state «up to date».
- [x] Футер: дочерний эмитит N/M; отдельное `structuralIndexProgress` не блокирует дерево/панель.
- [x] **Зависание устранено**: sample главного потока — нормальный event loop, 0 совпадений
      `waitUntilExit/GitClient.run`, CPU 0%, отзывчив.

---

## Active: Fix долгий старт (>5 мин) — индексация воркспейса

### Root cause (подтверждено кодом + логами)
`StructuralIndexer` при открытии папки обходит всё дерево **до 3 раз**:
1. Детект изменений (`StructuralIndexer.swift:27-55`) — `DispatchQueue.main.sync` **на каждый файл** + чтение всего содержимого каждого файла (FNV-хэш). N round-trip'ов к занятому главному потоку → зависание UI на минуты.
2. `indexModules` (:241) — 2-й обход + `contentsOfDirectory` на каждую папку.
3. `indexDocuments` (:308) — 3-й обход, читает и парсит каждый файл.

### План (одобрено: пункты 1+2+3)
- [ ] 1. Убрать `main.sync` из цикла — батч-фетч мета (hash+mtime) одним SELECT.
- [ ] 2. Детект по `contentModificationDate` (mtime); читать/парсить ТОЛЬКО изменённые.
- [ ] 3. Объединить три обхода дерева в один проход.

### Изменения
- [ ] `SemanticDatabase.upsertDocument(..., fileMtime:)` — писать `file_mtime` (колонка уже в схеме).
- [ ] `SemanticDatabase.allDocumentMeta()` — батч-фетч `[docId: (hash, mtime?)]`.
- [ ] `StructuralIndexer.indexAll()` — оркестратор: мета → один `scanTree` → батч-запись.
- [ ] `StructuralIndexer.scanTree` — один enumerator: модули + классификация файлов по mtime.
- [ ] `writeModules` / `writeChangedDocs` — батч-запись на MainActor (чанки 50).
- [ ] Удалить `indexModules` / `indexDocuments`. Схемы ID сохранены 1:1.

### Architecture change (по требованию пользователя)
Индексация вынесена в **отдельный процесс** (re-exec бинарника `MarkView --dde-index <folder>`),
а не фоновый Task внутри приложения. Sandbox отключён → Process + доступ к папкам разрешены.
- `MarkViewApp.swift`: `@main enum DDEAppEntry` перехватывает `--dde-index` до SwiftUI;
  `DDEIndexerRunner` гоняет `indexAll()` на `@MainActor` (SemanticDatabase изолирован),
  `dispatchMain()` обслуживает очередь, `exit()` по завершении. С `MarkViewApp` снят `@main`.
- `WorkspaceManager.runStructuralIndex`: спавнит `Process`, `terminationHandler` →
  `loadCachedResults()` + `refreshSemanticViews()`.
- `SemanticDatabase`: `PRAGMA busy_timeout = 5000` для кросс-процессного WAL.
- `runningIndexers` — **static** (процесс-wide), иначе `Process` освобождается вместе с
  временным WorkspaceManager (их при старте несколько) и terminationHandler не срабатывает.

### Verification (проверено на live-запуске, KnowledgeDB = 1222 .md)
- [x] Сборка: `xcodebuild Debug` → BUILD SUCCEEDED.
- [x] Out-of-process: дочерние процессы с отдельными PID (87768/88321/88789).
- [x] Первый индекс 1222 файлов: ~15с вне процесса (старый код висел >5 мин, БД 4KB/пустая).
- [x] Инкрементально: 1222 → ~1038 пропущено по mtime, ~1с; `file_mtime` заполнен 1038/1038.
- [x] terminationHandler срабатывает (`exited code=0`) → виды обновляются.

### Review
- Корневая причина >5 мин: НЕ парсинг JS (первая гипотеза была неверна), а индексация —
  3 обхода дерева + `DispatchQueue.main.sync` на каждый из 1222 файлов на занятом main-потоке.
- Известный pre-existing дефект (вне рамок задачи): `docId = имя файла`. В KnowledgeDB 1222
  файла при 1038 уникальных именах (184 коллизии) → совпадающие имена «мерцают» по mtime и
  реиндексируются каждый раз (~1с, не растёт). Фикс — сменить схему docId на относительный
  путь — затронет всю схему БД и весь код, использующий docId. Требует отдельного согласования.
- Удалённые/перемещённые файлы из БД не вычищаются (как и было). Вне рамок.

---

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

---

## Whole-document translation (RU/EN) — 2026-08-31

Selection translation worked, but whole-document translation was unreachable dead
code and had no Russian variant. Requirement: RU/EN with no selection proposes
translating the entire document into a copy, preserving all formatting.

- [x] Clear `formatBarSelectedText` when the selection collapses (`markview-edit.js`) —
      stale capture made RU/EN re-translate the previous selection forever.
- [x] Capture Source-mode selections from the `<textarea>` (`currentSourceSelection`) —
      `window.getSelection()` never covered it, so selection translation was dead in Source mode.
- [x] Replace the never-called `translateToEnglish()` with `translateWholeDocument(targetLang)`.
- [x] `selectionAction` with no selection now shows a confirm popup built from the
      `#action-popup` DOM (`window.confirm()` silently returns false in this WKWebView).
- [x] Remove the leftover `document.title = 'SEL[...]'` debug line.
- [x] Route the engine: Ollama when connected, else Anthropic, else a visible message
      in the editor popup (was a silent `NSLog` return). Added `ProviderRouter.ActionType.translate`.
- [x] Structure-aware `splitForTranslation` — atomic blocks (front matter, fenced code,
      tables, list/quote runs, paragraphs), never split mid-structure, lossless rejoin
      via per-block separators. Front matter and code fences are never sent to the model.
- [x] Per-chunk structural validation (`skeleton`) with one strict retry; on failure keep
      the source text and report it in the document instead of emitting corrupted markdown.
- [x] Live progress banner written into the translated tab (`indexingProgress` only shows
      in the file-tree sidebar, which is often collapsed).
- [x] Resolve the target tab by `OpenTab.id` instead of a captured index.
- [x] Add the missing HTTP status check; join all `content` text blocks, not just the first.

### Verification
- `xcodebuild ... build` → BUILD SUCCEEDED.
- Splitter extracted into `/tmp/splittest.swift` and exercised against a fixture with a
  GFM table, a leading-pipe-less table, a fence containing table-like and heading-like
  lines, nested lists with continuations, task lists and a block quote:
  lossless round-trip PASS, atomicity PASS at maxChars 4000 and 60.
  Edge cases PASS: no trailing newline, leading blank lines, CRLF, unclosed fence,
  whitespace-only, heading-only, unterminated front matter.
- `selectionAction` driven through a DOM stub in node: no-selection → proposal popup and
  no API call; confirm → `translateRequested`; `explain` with no selection → no-op;
  with a selection → unchanged popup path.
- App launched on `TestFiles/translation-fixture.md` — no `jsError` entries in
  `~/markview_debug.log`.

### Not fixed (found during review)
- `BlockIntelligenceView.swift:56` — the block-level "Translate" button calls
  `submitJob(.translateBlock)`, but `submitJob` ignores its argument and always calls
  `submitExtraction`. The button does not translate anything.
- Live translation quality with a table has not been exercised against a real API key
  or a running Ollama — needs a manual pass.

---

## Configurable AI CLI tools + Whisper diagnostics — 2026-09-03

Bug report: Codex (and possibly Claude and Whisper) stopped working, with no way to
reconfigure them from the UI.

### Diagnosis
- **Codex broken:** `AIConsoleEngine.codexPath = "/opt/homebrew/bin/codex"` did not
  exist. Real binary: `~/.nvm/versions/node/v22.22.3/bin/codex` (npm/nvm install).
  `codex login status` → logged in, so auth was fine — only the path was wrong.
- **Claude fine:** `~/.local/bin/claude` v2.1.259, `claude auth status` → loggedIn true.
- **Whisper config fine:** key present, mic permission granted (TCC=2), WAV settings
  correct, usage string present. No configuration fault found.
- **Installed app was 7 weeks stale** (Jul 16) — the likely reason Claude/Whisper
  "also" appeared broken.

### Changes
- [x] `CLIToolLocator` + `CLITool` in `AIConsoleEngine.swift` (no new files, so the
      hand-maintained pbxproj needs no regeneration). Resolution order: Settings
      override → candidate scan incl. every `~/.nvm/versions/node/*/bin` → login-shell
      `command -v`, off-main with a timeout.
- [x] Subprocess `PATH` now built from the tool's own dir + base dirs + all Node bin
      dirs + user's extra entries, replacing the fixed literal that omitted nvm.
- [x] Missing binary now writes an actionable message into the console (what, where
      searched, where to fix) instead of an opaque `process.run()` throw.
- [x] Settings → "AI CLI Tools": per-tool path field, Save, Auto-detect, Check
      (version + sign-in state), Login in Terminal, plus an extra-PATH field.
- [x] Terminal login via an executable `.command` file + `NSWorkspace.open` — avoids
      Apple Events and the automation permission prompt.
- [x] Settings → "Whisper": mic status (+ deep link to System Settings), key status,
      model picker (whisper-1 / gpt-4o-transcribe / gpt-4o-mini-transcribe), and a
      3-second record-and-transcribe self-test that prints the real API error.
- [x] `WhisperClient`: model from settings, HTTP status + model in the error text,
      `runSelfTest()`, removed the dead `.m4a` init path that disagreed with the
      `.wav` the multipart body declares.
- [x] Security: `DDESettingsView.onAppear` was logging the first 20 chars of both API
      keys to `~/markview_debug.log`. Now logs presence and length only.

### Verification
- `xcodebuild ... build` → BUILD SUCCEEDED.
- Locator exercised as a standalone binary against the real machine:
  claude → `/Users/boris/.local/bin/claude`, v2.1.259, loggedIn true;
  codex → `/Users/boris/.nvm/versions/node/v22.22.3/bin/codex`, v0.146.1, loggedIn true.
- Failure path: override set to a nonexistent file → "Path set in Settings does not
  exist or is not executable: …", no silent fallback. Auto-detect recovers.
- Login-shell fallback resolves codex independently of the candidate scan.
- Timeout guard: `/bin/sleep 30` with a 2s budget terminated at 2.0s, exit -2.
- App launched from the Debug build: runs clean, no key material in the debug log.

### Left for manual check
- Console round-trip on each backend (needs UI; `codex exec --full-auto` can write
  files, so it was not run headlessly).
- Whisper 3-second self-test (needs a microphone and a click).

## AI assistant + model selection (Claude / Codex) — 2026-09-24

Goal: choose which CLI (Claude Code / Codex) and which model answers AI Console
requests — every "ask AI" path (console input, AI tools, graph edit, docs) goes
through `AIConsoleEngine.sendMessage`. Configurable in DDE Settings, quick-switchable
from the AI panel via a popover dialog. One source of truth: UserDefaults.

- [x] `AIAssistantPreferences` (AIConsoleEngine.swift): keys `settings.ai.backend`,
      `settings.cli.<tool>Model` ("" = CLI default); model catalog per tool —
      Claude aliases (fable/opus/sonnet/haiku), Codex list read from
      `~/.codex/models_cache.json` (visibility == "list"), custom name always allowed.
- [x] Engine: backend read from preferences; pass `--model` (claude) / `-m` (codex);
      when backend changes between turns, drop the CLI session ids and post a system
      note instead of wiping the visible history.
- [x] AI panel: replace the two-tab header with a "Claude Code · opus ▾" button that
      opens a popover (assistant segmented picker, model list, custom model field);
      input placeholder names the active assistant.
- [x] DDE Settings → AI CLI Tools: "Default assistant" picker + per-tool model picker.
- [x] Build; verify CLI args with both backends; manual UI check.

### Verification
- `xcodebuild ... build` → BUILD SUCCEEDED; no new warnings in touched files (the
  old off-actor reads of `backend`/session state are gone).
- Exact argument shapes the engine builds, run against the real CLIs:
  claude fresh `--model haiku` → init model claude-haiku-4-5, "OK";
  claude `--resume <id> --model sonnet` → claude-sonnet-5, "OK2" (model switch keeps session);
  codex `exec --full-auto --skip-git-repo-check -m gpt-5.5` → "OK";
  codex `exec resume --last ... -m gpt-5.5` → "OK2".
- Codex catalog lists models the account may not be allowed to use (e.g. gpt-6-luna
  on a ChatGPT login → HTTP 400); the CLI's error text reaches the console as an error.

### Left for manual check
- Popover and Settings picker in the running app (UI).

## Close Folder — 2026-09-24

Goal: close the open workspace and return to the welcome screen to pick another folder.

- [x] `WorkspaceManager.closeFolder() -> Bool`: one "save changes to N documents?"
      prompt (Save All / Don't Save / Cancel; abort if a save fails), cancel insight
      sessions, stop the AI console run, terminate this window's structural-index
      child, stop the file watcher, drop tabs, tree, engines and git state.
- [x] Share the engine teardown with `initSingleFileWorkspace` (`releaseWorkspaceEngines`).
- [x] `GitClient.reset()` so the branch bar disappears.
- [x] UI: File → Close Folder menu item; ✕ button on the file-tree breadcrumb bar;
      "Open Folder…" button in the empty file tree; breadcrumb state resets when the
      root changes.
- [x] Build, deploy locally, manual check.

### Verification
- Debug + Release builds succeed; installed to /Applications.
- File → Close Folder ran `closeFolder` (log line with folder path); window returned
  to the welcome screen.
- Menu item was stuck disabled (Commands don't observe the focused WorkspaceManager);
  fixed with a value-typed `workspaceHasFolder` focused value.
- User confirmed Close Folder works in the installed build.

## Remove "modules" feature + Ollama from UI — 2026-09-24

Decisions (user): Ollama hidden from UI only — translation keeps using it silently;
remove feature + engines but keep the indexer's `mod_` folder rows (no DB migration);
delete already-dead code.

- [x] Semantic panel (`ModuleExplorerView`): drop Modules tab, per-module actions
      (Describe/Summary/Diagram/Tests/ADR), module count, ↻ extract button, dead
      Research tab; re-index remaining tabs (Search/Git/Diagrams/AI) and migrate the
      stored tab index.
- [x] Component extraction: `StructuralIndexer.extractContentModules` & co.,
      `WorkspaceManager.extractSingleFileComponents/extractWithOllama/chunkContent`,
      `reindexActiveFile`, extraction tail of `reindexFile`, disabled auto-extract,
      `excludeFolder` component cleanup.
- [x] Delete engines used only by modules or dead: ActionEngine, TestGenerator,
      ImplementEngine, ResearchEngine, HybridSearch; dead views CanvasView,
      SemanticPanelView; GraphRAG community functions. Update pbxproj.
- [x] Prompts: `diagramSummaries`, `documentationGenerationPrompt`,
      `AIConsoleEngine.generateSkillFile` stop reading `cmod_` components;
      delete unreachable code after `diagramSummaries` return.
- [x] Ollama: remove Settings box and `extractionSystemPrompt`/`extractJSON`; keep
      `OllamaClient.checkConnection/generate` for translation.
- [x] SemanticDatabase: remove helpers left without callers; README.
- [ ] Build, deploy locally, manual check (Semantic panel tabs, translation, AI console).

### Verification
- Debug build succeeds, no new warnings. 7 files deleted (ActionEngine, TestGenerator,
  ImplementEngine, ResearchEngine, HybridSearch, CanvasView, SemanticPanelView) and
  their pbxproj entries; 11 DB helpers + 4 row types left without callers removed.
- `apiKeyValue` (translation) lived in ActionEngine.swift — moved to AIProviderClient.swift.
- Headless `--dde-index` on a TestFiles copy: 7 docs, 32 headings, 7 code blocks, one
  per-folder row, no components; second run takes the "up to date" fast path.
- Existing databases keep old `cmod_` rows; nothing reads them (the skill-file outline
  filters them out).

### Left for manual check
- Right panel shows Search / Git / Diagrams / AI; a stored "Modules" selection opens Search.
- DDE Settings: no Ollama box; OpenAI box reads "Whisper voice input".
- Translation still works (Anthropic; Ollama if running).

## Route AI features through Claude Code / Codex CLI; drop Anthropic HTTP + Ollama — 2026-09-24

User decisions: port everything (incl. Recursive Insight), remove Ollama, fix key leak.
The CLI + model come from `AIAssistantPreferences` (same choice as the AI console).

Probed CLI behaviour (2026-09-24):
- claude `-p --safe-mode --tools "" --no-session-persistence --output-format stream-json
  --verbose --include-partial-messages [--model] [--system-prompt] [--json-schema]`,
  prompt on stdin → `stream_event` text deltas; final `result` has `result`,
  `structured_output`, `total_cost_usd`, `usage`, `is_error`.
- codex `exec --sandbox read-only --skip-git-repo-check --ephemeral --json
  [-m] [--output-schema file] -` → no token streaming; `item.completed`
  agent_message holds the whole answer; `turn.completed` has token usage, no cost;
  schema must be strict (additionalProperties false, all keys required).

- [x] Key leak: 5 key prefixes in ~/markview_debug.log redacted in place.
- [x] `CLICompletion` one-shot runner: stdin prompt, system prompt, JSON schema,
      optional read-only folder access, deltas, usage → `usage_stats`, timeout, errors
      that say what failed and where to fix it.
- [x] Selection actions (RU/EN/?) → CLI.
- [x] Whole-document translation → CLI; remove Ollama engine.
- [x] Architecture diagrams → CLI with JSON schema.
- [x] Recursive Insight: classify, skeleton (schema), sections (streaming, ≤5 parallel)
      → CLI. Prompts unchanged (parity first).
- [x] Remove: Anthropic key box + verify, `AIProviderClient` HTTP/SSE, `ProviderRouter`,
      unreachable extraction pipeline (AIOrchestrator jobs, analyzeAllFiles,
      BlockIntelligenceView), OllamaClient, dead privacy picker.
- [ ] Build, deploy, manual check of each feature with Claude and with Codex.

### Verification
- Debug build succeeds; no new warnings in touched files.
- `CLICompletion` exercised in a standalone harness against the real CLIs:
  claude (haiku) text with 3 streamed deltas + cost; codex (gpt-5.5) text in one
  delta, tokens, no cost; diagram schema returns structured diagrams on both;
  cancelling the task terminates the process (CancellationError) on both.
- Insight skeleton schema: claude → 11 sections; codex first rejected the open
  `metadata` object (strict mode) → metadata now declares hasMath/chartType/axisLabel
  and `strictSchema` closes any other open object → codex 9 sections.
- Removed files: AIProviderClient, AIOrchestrator, ProviderRouter, OllamaClient,
  CompileEngine, CompilePanelView, BlockIntelligenceView, CacheManager,
  SemanticReconciler, OverlayManager, MarkdownBlockParser (+ pbxproj); added
  CLICompletion, DiagramGenerator.
- Settings: Anthropic box (and its auto key check that cost a request per open),
  privacy picker (unwired), pipeline Status box removed.

### Left for manual check (UI)
- RU / EN / ? on a selection; whole-document translation; Diagrams → Rerun
  (errors now show in the tab); Recursive Insight end to end — each with Claude and Codex.
- Codex: Insight sections appear whole (no token streaming); ~14K tokens of Codex's own
  prompt per call.
- The old Anthropic key is still stored in UserDefaults (`com.markview.dde.apikey`);
  nothing reads it now.

## AI panel: Diagrams tab → Actions (per-document AI actions) — 2026-09-24

User decisions: results open in a new unsaved tab; base actions + AI-suggested ones;
when the document changed since analysis, show a note + Reanalyze (never auto-run).
Keep the "Diagrams" section in the toolbar AI Tools menu.

- [x] Model + store: `DocumentAnalysis` (content hash, type, summary, AI actions) cached
      as JSON under `<workspace>/.dde/cache/actions/`, loaded on demand.
- [x] Analyze via `CLICompletion` + JSON schema; Reanalyze; stale detection by hash.
- [x] Base actions: Executive summary, Key decisions, Risks & open questions,
      Action items, Glossary, FAQ. Plus a free-form "custom action" field.
- [x] Run action → new unsaved tab next to the document, streamed while generating;
      never overwrites an existing file name.
- [x] `ActionsView` replaces `EntityGraphView`; AI panel tab "Diagrams" → "Actions".
- [x] Remove the architecture-diagram machinery only the old tab used.
- [ ] Build, deploy, manual check with Claude and Codex.
- [x] Output language picker in the Actions header (Document language / English /
      Русский / …), stored in `actions.outputLanguage`; applies to results.

### Verification
- Debug build succeeds. Removed EntityGraphView.swift (kept `MarkdownContentView`,
  moved into AIConsoleView.swift — the console renders with it) and DiagramGenerator.swift.
- Harness on TestFiles/demo.md: claude (sonnet) 24 s → 9 document-specific actions;
  codex (gpt-5.5) 29 s → 8; cache reloads from disk, not stale.
- Running "Executive summary" with Russian output (claude): 240 streamed deltas,
  markdown starting with an H1, assumptions marked.

### Left for manual check
- Actions tab in the app: Analyze → buttons; Reanalyze; stale note after editing;
  result tab opens and streams; custom action; language menu.

## Code viewer + Visual Architecture — 2026-09-24

User decisions: CodeMirror 6 (bundled, read-only viewer, later the source editor);
Cytoscape.js + ELK (bundled); hybrid analysis (deterministic scan + read-only AI
enrichment, stored in SQLite, incremental); PR overlay from branch-vs-base and GitHub
PR via `gh`.

- [x] A. Code viewer: vendor CodeMirror 6 bundle (tools/codemirror-bundle → vendor/js),
      code file types in tree/tabs, read-only view with highlighting, line numbers,
      folding, indent guides, go-to-line.
- [x] B. Architecture model: scanner (git ls-files / walk, languages, LOC, dir tree,
      imports for JS/TS/Python/Go/Rust/C/C++/Ruby, type-reference fallback for
      Swift/Java/Kotlin/C#), `arch_*` tables, Architecture tab (Cytoscape + ELK):
      drill-down into modules keeps external edges (edge aggregation to visible
      ancestors), details panel, open file at line.
- [x] C. AI enrichment (module names/summaries/roles), Deployment view (AI over config
      files found by the scanner), Docs architecture view (doc links + doc→code refs).
- [x] D. Overlays: doc coverage (none / fresh / stale via git commit times);
      PR (branch vs base or `gh pr`), AI review per file → colour by risk.
- [x] E. Code-folder behaviour, menu/toolbar entry, bump minor → 1.1.0, deploy.

Added during the work (user requests): incremental updates (node signatures → AI
re-describes only changed modules, deployment only when its config changed; rescan
on every open), overlays Tests (lcov/Cobertura or import/name heuristic), Bug history
(fix-commit counts), Freshness (last commit), Complexity (decision points), Size;
Docs view zooms into document sections; section/mention links open the markdown
at that place.

### Verification
- Debug + Release builds succeed; installed 1.1.0.
- Code viewer (Chrome against the bundled editor page): Swift + JS highlighting, line
  numbers, folding, indent guides, dark theme, goto lines 47–52 selected and centred.
- Scanner harness: MarkView 0.85 s (78 files, 130 type-reference + JS import edges,
  npm externals, coverage fresh/stale/none, deploy hints incl. GitHub workflow);
  erpnext 3005 Python files in 2 s (2055 imports); LLM-Engineers-Handbook,
  astroweb (TS) OK. Minified/bundled/over-512 KB files excluded.
- Architecture tab (Chrome, real payload): top level, zoom into External and
  MarkView/Models keeps outside edges, Documentation / Bug history overlays,
  Health panel, Docs view → CLAUDE.md sections in order → openFile{find}.

### Not verified here (needs the app UI)
- Tab opening from ⌘4 / toolbar / auto-open for code folders, persistence in
  state.db, Analyze (AI modules + deployment), Changes overlay with git/gh and the
  AI review, markdown scroll-to-heading after openFile.

## Architecture v2: logical view, honest metrics, on-demand descriptions — 2026-09-24

User feedback on 1.1.0 (tested on broker-fabric / apps/bf-menubar):
- [ ] Do not auto-open Architecture; explicit "Open Architecture" (welcome screen + file
      tree header + ⌘4/toolbar). Opening it the first time runs the AI analysis.
- [ ] Logical view (AI): system purpose, nested components with purpose, every folder/file
      assigned to a component and tagged (entry, ui, api, domain, data, integration, infra,
      config, build, tests, docs, generated, scripts). Structure view keeps the file system,
      can hide tests/config/build/docs/generated and colour by component. Manual
      reassignment of a folder/file to another component, stored as an override.
- [ ] Descriptions on demand: selecting an undescribed node asks the AI (cached by signature).
- [ ] Deployment always produced by the analysis; clear call to action when missing.
- [ ] Metrics that match their colours: complexity = per-function cyclomatic (McCabe
      thresholds 10/20), bug history = absolute fix counts, module colour = worst file;
      freshness colour = last change; doc coverage counts folder mentions only for
      specific folders (≤ 25 files).
- [ ] Code viewer "Explain" (user request): AI splits the file into sections; a margin panel
      beside the code (Word-style comments) aligned to each section, scroll-synced, cached.
- [ ] Importance (user request): Architecture overlay by dependency centrality (fan-in,
      transitive dependents, entry points); in Explain, each section gets an importance level.

## AI panel: terminals only, prompt buttons, image viewer (2026-09-24)
- [x] Remove the Actions tab, `ActionsView`, `DocumentActionsStore`/`DocumentAction*` and `runDocumentAction`; keep `ActionOutputLanguage` and the content hash (X-Ray, Explain) in `OutputLanguage.swift`
- [x] AI panel = Terminal only: several terminals side by side (Claude Code, Codex, plain shell), sub-tab bar with "+" menu, close, restart
- [x] Prompt buttons that paste a ready prompt into the active assistant terminal (Review PR… with a PR field, Review my changes, Docs ↔ code sync, Explain file, Find bugs, Write tests, Commit message, Security review, Update docs)
- [x] Image viewer tab (`TabKind.image`): PNG/JPEG/GIF/HEIC/WebP/TIFF/BMP/ICO/SVG…, wheel/pinch zoom around the cursor, drag to pan, fit / 100 %, drop images to open, drag the image out
- [x] Build, harness-check, bump minor, install

### Review
- Built; terminal harness: profile switch restarts with a full reset (mouse mode off). Canvas harness: fit 67 %, wheel zoom keeps the point under the cursor, ⇧+wheel pans, 1:1 = 400×200 px.
- Not verified in the running app: the panel layout, the PR popover (needs `gh`), drag-and-drop in and out.

## Logical X-Ray: contents of files (2026-09-24)
- [x] Files still grouped into subsystems → components (clusters); under each file its contents (`XRayContent`)
- [x] Markdown: assistant finds collections → types → items (e.g. Issues → bug/feature/chore → each issue), with line
- [x] Long code (≥ 250 lines): assistant splits into logical parts → roles → every function/type; short code: local declarations (≥ 2)
- [x] Analysis step 4 "Reading contents" (up to 60 files, longest first, 4 in parallel); on open: stored outlines + new/changed files; details panel "Break down contents"
- [x] Double-click an item opens the file scrolled to it (line for code, line text for markdown)
### Review
- Real claude runs: sample backlog → Issues (bug 4, feature 3, chore 2) + Decisions, lines right, 6 s; TerminalSession.swift / ImageViewerView.swift → 6–7 logical parts. Labels in the file's language, summaries in the AI language.
- Web view harness: drill-down Logical › Planning › Backlog › BACKLOG.md › Issues › bug renders, no JS errors.
- Not verified in the running app: step 4 on a real project, opening an item scrolled in rendered markdown.

## PR X-Ray: inside a changed file show only its changes (2026-09-24)
- [x] Swift: `PRChangeNote` per changed file — deterministic (touched ranges → X-Ray content parts/items, else "Lines a–b"); AI "explain changes" per file (diff only → title, kind, why), cached; `explainPRFile` action
- [x] JS PR view: a changed file expands into part → change nodes (not the whole file); selecting a file asks for the explanation
- [x] JS details for a change: why, kind, lines, only its hunks of the diff, open at line, Ask AI
- [x] Build, harness render, bump patch (no install)
### Review
- Real diff (FileTreeView reveal fix) → claude: 5 logical changes with right lines, only what changed (6 s).
- Web view harness: PR X-Ray file expands into State / Layout / Reveal / Rows → changes (kind, lines); a change shows its why and only its hunk.
- Found and fixed on the way: overlays, PR highlighting and "Hide tests" treated a file with inner nodes (contents, changes) as a container → `descendantsFiles` stops at files; inner nodes take their file's colour.
- Not verified in the running app (not installed: Boris is using it).

## Pull request lens in the file viewer (2026-09-24, 1.26.0)
- [x] Code/notes viewer lens "⎇ Pull request" (when a PR is loaded in X-Ray and the file is in it): added lines tinted, removal points marked, heat strip; a note per change with kind, lines, why (AI) and its own diff lines; PR title, +/−, summary in the legend
- [x] Opening a file from the PR X-Ray (or with the PR overlay) starts on that lens; the explanation is requested automatically
- [x] Logical X-Ray with the Pull request overlay: a changed file's details show its change (summary, diff, Ask AI)
- [x] Terminal no longer inherits CLAUDECODE / CLAUDE_CODE_* from the process that launched MarkView (verified: 8 in the parent env → 0 in the shell)
### Review
- Web view harness with the real FileTreeView diff: lens auto-selected, 5 change notes, 6 bands, no JS errors. PR X-Ray regression render unchanged.
- Not installed (Boris is using the app).

## X-Ray toolbar, review again, tasks from the review (2026-09-24, 1.26.0)
- [x] Analyze / Rescan / Fit / Details kept together; a narrow toolbar moves the group to the next line as a whole
- [x] "Review again" (after a review): reload the change as it is now, review without the cached answer; also repeats the analysis if there was one; "Analyze again" bypasses the cache
- [x] "N tasks found" in the PR panel: Send to terminal (typed at the assistant prompt, not sent) / Copy — bugs, concerns, notes, checks and risks as markdown tasks with path:line
### Review
- Harness: wide and 620 px wide PR panel — buttons on one row (tops 6,6,6,6 / 33,33,33,33), "Review again", "4 tasks found", no JS errors.
- Not installed.

## Changes in sync, local vs main, fetched PRs, terminal keys (2026-09-24, 1.27.0)
- [x] Root cause of "not in sync": the PR X-Ray kept a diff loaded before a later commit (429 → 499 lines)
- [x] Pull request lens matches the diff's lines to the file by content (LCS) — bands, notes and lines follow the current file; local changes reload by themselves when the file moved on (review kept, marked outdated)
- [x] Sources: "All changes vs main (commits + uncommitted + new files)" (default when the PR X-Ray opens) and GitHub pull requests; "Uncommitted changes" / "branch vs base" removed
- [x] A GitHub PR is fetched (`pull/N/head`, base; no checkout) and diffed locally (merge-base → head); files open in their PR version (cached snapshot) — always in sync; falls back to `gh pr diff`
- [x] Terminal: Shift+Enter = new line (LF); ⌘V of an image saves a PNG and types its path, of Finder files types their paths
### Review
- Harness: Shift+Enter → '\n', Enter → '\r'; private pasteboard image → valid PNG path typed.
- PR 161 fetch steps run by hand: head present, base fetched, 35 files diff, working copy and branch untouched.
- Not verified in the running app; not installed.
