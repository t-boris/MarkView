---
type: bug
id: BUG-044
title: Opening X-Ray starts gh in the background while the GitHub integration is off
status: fixed
branch: fix/bug-044-xray-gh-opt-in
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Opening X-Ray starts gh in the background while the GitHub integration is off

## Summary

`ArchitectureStore.open(root:db:)` calls `refreshPRSources(root:)` every time an X-Ray opens. That runs `listPRSources`, which starts `gh` through `ArchitectureStore.runGH`, a second `gh` runner that never checks the GitHub opt-in (`ArchitectureStore.swift` does not reference `GitHubSettings`). The project rule is that GitHub is an opt-in integration and MarkView never runs `gh` while it is off (`GitHubStore.swift` says so). `runGH` also reads the pipe to the end and calls `waitUntilExit()` with no timeout, so a stuck `gh` hangs that task. The same runner serves `fetchPR`, the `gh pr diff` fallback and the pull-request picker. Found while fixing BUG-034; the call path was read, not run. (Re-filed: the first copy collided with another BUG-042 created in parallel.)

## Steps to reproduce

1. Turn the GitHub integration off in Settings.
2. Open a git project whose origin is on GitHub and open its X-Ray (any view).
3. Watch for a `gh` child process (Activity Monitor or `ps`).

## Expected

No `gh` process starts while the integration is off. The PR X-Ray still offers the local checkout and branch comparisons, which need only git.

## Actual

`refreshPRSources` runs on every X-Ray open and starts `gh pr list` with no opt-in check and no timeout.

## Environment

MarkView main (b2df2b9), MarkView/Models/ArchitectureStore.swift `refreshPRSources`, `listPRSources`, `runGH`; MarkView/Models/WorkspaceManager.swift callers of `refreshPRSources`; code reading only.

## Cause

The PR X-Ray had its own `gh` runner, `ArchitectureStore.runGH`, next to `GitHubClient`, and nothing on its
call path asked the GitHub switch.

- `ArchitectureStore.open(root:db:)` calls `refreshPRSources(root:)` whenever an X-Ray opens; `openPRXRay`,
  `compareBranch` and the bridge action `refreshPRSources` call it again. It runs `listPRSources`, which asks
  `gh pr list` twice (open, then recently closed) for the source picker, with the local checkout from git.
- `runGH` was a bare `Process` wrapper: it located `gh` on the AI CLIs' PATH, started it, read standard output to
  the end and called `waitUntilExit()`. No opt-in check, no timeout, nothing closing stdin, and reading one pipe to
  EOF before waiting (the pattern CLAUDE.md warns against; `GitHubClient` already had a bounded drain loop).
- The same runner served `fetchPR` (`gh pr view`, from `loadPR`), the `gh pr diff` fallback in
  `diff(for:root:repo:)` (from `loadPR`, `analyzePR` and `reviewPR`) and `openPullRequests` (the pull-request
  picker popover in `TerminalView`).
- BUG-034 fixed the same omission in "I Need to Understand" and recorded this runner as the next case.

## Resolution

`gh` for the PR X-Ray now goes through `GitHubClient`'s runner and runs only when the GitHub integration is on,
using the switch every other caller uses (`GitHubSettings.enabled`, key `settings.github.enabled`). No second
switch was added.

- `GitHubClient.output(_:in:enabled:timeout:)` (new, `MarkView/Models/GitHubClient.swift`) is a blocking entry
  to the runner behind `GitHubClient.execute`: the same `gh` lookup and PATH, stdin closed, both pipes drained
  while the process runs, the process terminated (then killed) after `timeout` seconds. It returns standard output
  when `gh` exits with 0 and nil otherwise. With `enabled` false it returns nil before touching `Process`, so a
  caller that passes `false` cannot start `gh`. `GitHubClient.execute` itself is unchanged and still ungated: it
  also runs `git` for callers that must work with the integration off (see BUG-034).
- `ArchitectureStore.runGH` keeps only the `-R <slug>` insertion for the repository chosen in the Git tab and
  calls `GitHubClient.output`. It takes a required `gitHub: Bool` and a `timeout` (20 s; 60 s for `gh pr diff`,
  which downloads a whole diff). It is the only place in the file that starts `gh`.
- `listPRSources`, `openPullRequests`, `fetchPR` and `diff(for:root:repo:)` take the required `gitHub` argument
  and pass it on. With the integration off `listPRSources` still returns the git-only sources (the local checkout;
  branch comparisons are kept by `refreshPRSources` as before) and simply has no GitHub pull requests;
  `openPullRequests` returns an empty list, so the picker shows "No open pull requests found (gh)."; `fetchPR`
  and the diff of a `gh:<n>` source are nil.
- The switch is read once per operation on the main actor and handed into the detached work, the way the BUG-034
  fix does, so the nonisolated static functions stay free of settings access: `refreshPRSources`, `loadPR`,
  `analyzePR` and `reviewPR` in `ArchitectureStore`, and the picker's `.task` in `TerminalView`.
- When a pull request cannot be loaded because the integration is off, the PR X-Ray's error says so ("the GitHub
  integration is turned off in Settings") instead of suggesting that `gh` is not installed or signed in. A
  `gh:<n>` source can only be asked for explicitly (a typed number, Review on a pull request, an MCP call), so this
  message is an answer to a request, not an unprompted mention of the integration.

## Not changed

- Git stays: `git rev-parse`, `symbolic-ref`, `merge-base`, `diff` and the untracked-file diff behind the local
  source and the branch comparisons use `ArchitectureScanner.runTool` and work with the integration off. That
  runner still reads its pipe to EOF before `waitUntilExit()`; it runs short local git commands with no network
  and is outside this bug.
- `GitHubClient.execute` and its callers (`GitHubStore`, `IssueSyncRun`, `XRaySearch` through
  `PullRequestHistory`) are unchanged; their gating is described in BUG-034.
- `GitHubPublisher` (Publish to GitHub) still runs `gh` without the switch; it is started by the person asking to
  publish and turns the integration on when it succeeds (recorded in BUG-034, not part of this bug).
- The picker's "No open pull requests found (gh)." text is the same with the integration off as with `gh`
  missing; the popover is a prompt helper for the AI review and does not explain the integration.
- `refreshPRSources` still runs on every X-Ray open. With the integration off it now costs a few local git
  commands and no `gh`; with it on it behaves as before, except that a stuck `gh pr list` gives up after 20 s.

## Verification

- `bash tools/tests/github-command-tests.sh` passes. It compiles `GitHubClient.swift` on its own and runs it with
  a fake `gh` (the test binary itself, symlinked as `gh` on a private PATH); the new part exercises
  `GitHubClient.output`:
  - integration off: nil, and the fake `gh` leaves no trace of having started, even though it would have printed
    output;
  - integration on: the fake is started, its trace exists and its standard output comes back;
  - a `gh` that exits non-zero gives nil, not partial output;
  - a `gh` that ignores SIGTERM gives nil within the 1 s timeout plus the kill grace, instead of hanging.
  The existing checks of the shared runner (full stdout and stderr pipes drained without loss, inherited writers,
  reaping of timed-out children, parallel requests) cover the timeout and drain behaviour `runGH` now inherits.
- `bash tools/tests/pull-request-history-tests.sh` and `bash tools/tests/code-architecture-tests.sh` still pass.
- Debug build with `xcodebuild` (see CLAUDE.md) passes. No file was added, so `project.yml` and
  `MarkView.xcodeproj` are untouched.
- Not exercised by a run: the real app with the switch off, opening an X-Ray and checking the process list for
  `gh` (the Steps to reproduce above); the PR X-Ray with the switch on against a real repository; the picker
  popover. `ArchitectureStore` and `TerminalView` are covered by the build and by reading the call path: every
  call of `runGH` (`listPRSources`, `openPullRequests`, `fetchPR`, `diff`) carries `gitHub`, every entry point
  that reaches them (`refreshPRSources`, `loadPR`, `analyzePR`, `reviewPR`, the picker's `.task`) reads
  `GitHubSettings.enabled` on the main actor, and `GitHubClient.output` returns before `Process` when the flag is
  false. The test cannot catch someone later passing `true` without reading the setting; the parameter is required
  at every call so the choice is visible at each site.
