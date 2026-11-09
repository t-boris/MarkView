---
type: bug
id: BUG-034
title: "\"I Need to Understand\" runs gh pr list while the GitHub integration is off"
status: done
branch: fix/bug-034-understand-gh-opt-in
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# "I Need to Understand" runs gh pr list while the GitHub integration is off

## Summary

`XRaySearch` runs `gh pr list --state all --limit 50` for every repository question and does not check the GitHub opt-in. `GitHubStore` documents that with the integration off MarkView never runs `gh`, and the project rule is that integrations are opt-in and silent when off. The feature's DEC-001 asks for PR data, so the fix needs a decision: gate the call on the opt-in, or amend the rule. Found by a read-only audit; not observed at runtime.

## Steps to reproduce

1. Turn the GitHub integration off in Settings.
2. Open a git project whose origin is on GitHub and ask a question with I Need to Understand.
3. While the answer runs, look for a `gh` child process (Activity Monitor or `ps`).

## Expected

No `gh` process starts; the answer notes that no PR data was available.

## Actual

`GitHubClient.execute` has no opt-in check, so `gh pr list` runs (20 s timeout) and the PR titles and bodies are given to the assistant.

## Environment

MarkView current main (ade7910), MarkView/Models/XRaySearch.swift line 63, MarkView/Models/GitHubStore.swift line 7; code reading only.

## Cause

The pull-request lookup of "I Need to Understand" started `gh` on its own, without asking the GitHub switch.

- `ArchitectureStore` (the understanding run) calls `XRaySearch.provenance(root:files:)` for every repository
  question. That function started `GitHubClient.execute(["pr", "list", "--state", "all", "--limit", "50", ...])`
  next to its plain `git log` and `git blame` calls.
- `GitHubClient.execute` is a bare process runner. It has no opt-in check, and cannot have one: the same function runs
  `git` for many callers that must work with the integration off. Every other `gh` caller gets its protection from
  somewhere else (`GitHubStore.setup` and `IssueSyncRun.start` test `GitHubSettings.enabled`, and the store's client
  exists only after a gated setup). `XRaySearch.provenance` did not go through any of them.
- DEC-001 asked for PR data and said the answer must degrade gracefully when PR access is unavailable. Nobody had
  recorded that the integration switch is one of the ways PR access can be unavailable.

## Resolution

The pull-request lookup now runs only when the GitHub integration is on, using the switch the other callers use
(`GitHubSettings.enabled`, key `settings.github.enabled`). No second switch was added.

- `PullRequestHistory` (new, `MarkView/Models/PullRequestHistory.swift`, Foundation only) builds the
  pull-request part of the history context. `section(enabled:fetch:)` starts `fetch` (the `gh pr list` call) only when
  `enabled` is true. When it is false the context says: "PR data unavailable: the GitHub integration is turned off in
  MarkView settings, so pull requests were not read. Do not invent PRs." and no pull-request URL can be cited, so the
  answer reports that no PR data was available. This is the path the answer already took for "gh missing, offline,
  or no GitHub repository"; only the reason differs.
- `XRaySearch.provenance` takes a required `includePullRequests` argument and hands the `gh` call to
  `PullRequestHistory.section` as the closure. The parsing, the 50-record and 1600-character bounds and the text for
  the enabled case moved into `PullRequestHistory` unchanged.
- `ArchitectureStore` reads `GitHubSettings.enabled` once and passes it in. The progress line reads "Reading git
  history…" instead of "Reading git history and pull requests…" when the integration is off, so the screen does not
  mention a lookup that does not happen.

## Not changed

- Git history stays: `git log`, per-file `git log`, `git blame` and `git remote get-url origin` use plain `git`,
  work with the integration off and are unchanged. The commit link hint (`https://github.com/<slug>/commit/<hash>`)
  is built from the local remote URL as text; nothing contacts GitHub.
- DEC-001 and REQ-002 are not edited. DEC-001 already requires graceful degradation when PR data is unavailable. With
  the integration off, the origin section can cite documents and commits but not pull requests.
- The answering agent cannot run `gh` itself: its tools are Read, Grep and Glob (`CLICompletion`), and its prompt says
  git and PR data are supplied read-only.
- Other `gh` calls found while auditing that run without the opt-in. They are not on this code path and are not
  changed here; they look like the same kind of bug and should be filed separately:
  - `ArchitectureStore.runGH` is a second `gh` runner next to `GitHubClient`, with no check of the switch. Its callers:
    `listPRSources` (two `gh pr list` queries) through `refreshPRSources`, which `ArchitectureStore.open(root:db:)`
    calls every time the X-Ray opens, and again from `openPRXRay`, `compareBranch` and the bridge action
    `refreshPRSources`; `fetchPR` (`gh pr view`, used by `loadPR` and `diff(for:root:repo:)`) and the `gh pr diff`
    fallback in `diff(for:root:repo:)`; `openPullRequests` (`gh pr list`) for the pull-request picker popover in
    `TerminalView`. Opening the plain X-Ray with the integration off therefore starts `gh` in the background. `runGH`
    also reads the pipe to its end and calls `Process.waitUntilExit()` with no timeout.
  - `GitHubPublisher` (Publish to GitHub, Connect to GitHub in the new-project sheet) runs `gh auth`/`api`/`repo
    create` without checking the switch. It is started by the person asking to publish, and a successful publish turns
    the integration on (`activateGitHub`), so this looks intended; recorded for completeness.
  - Prompt text that asks an AI agent to run `gh` (the PR review template in `AIPrompts`, `DeploymentPrompt` and
    `ProjectOperationDiscoveryService`) is not MarkView starting `gh`. Those agents' tool sets were not checked.
- Callers that look ungated but are not: `IssueSyncRun` (checks `GitHubSettings.enabled` in `start`), `GitHubStore`
  (checks it in `setup`, `reset()` clears the repository and client), `FeatureAI`/`FeatureIntake`/`FeatureIngest`
  (use `gitHubClient()`, which is `GitHubStore.client` and nil while no repository is selected), the lifecycle sync
  (called only from the store's poll) and the Settings account check (shown and run only when the switch is on, or when
  Check is pressed).

## Verification

- `bash tools/tests/pull-request-history-tests.sh` passes. It compiles `PullRequestHistory.swift` on its own and runs it
  with a fake `gh` that counts its starts:
  - integration off: the fake is started 0 times, the context says no PR data was available and why, and no URL
    can be cited, even when the fake would have returned pull requests;
  - integration on: the fake is started once, titles, bodies and URLs are listed, and the 50-record and 1600-character
    bounds hold;
  - integration on but `gh` missing, failing or answering with something that is not a list: the "unavailable" note, as
    before; an empty list: "No pull requests found.".
  The same checks fail (6 failures, all in the "off" case) against a copy of the module with the gate removed.
- Debug build with `xcodebuild` (see CLAUDE.md) passes. `MarkView.xcodeproj` was regenerated with XcodeGen; its only
  change is the four entries for the new file.
- `tools/tests/understanding-answer-tests.sh` and `tools/tests/github-command-tests.sh` still pass.
- Not exercised by a run: the real app with the switch off, an actual question in I Need to Understand and a check of
  the process list for `gh` (the Steps to reproduce above). `XRaySearch.provenance` and `ArchitectureStore` are covered
  by the build and by reading the call path: the only caller of `provenance` is the understanding run, the only `gh`
  start in `provenance` is the closure given to `PullRequestHistory.section`, and `section` returns before calling it
  when `enabled` is false. The test cannot catch someone later passing `true` without reading the setting; the single
  call site reads `GitHubSettings.enabled`.
