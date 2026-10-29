---
type: bug
id: BUG-029
title: GitHub Actions stays loading after gh has already exited
status: fixed
branch: fix/bug-029-github-actions-loading
severity: high
reporter: Boris Tsekinovsky
created: 2026-10-29
---

# GitHub Actions stays loading after gh has already exited

## Evidence and cause

The installed 4.60.1 process had ten background GitHubClient workers blocked in
readDataToEndOfFile, while its main thread remained responsive and no gh child was still running.
The process's pipe endpoints were also present in long-lived terminal shells and their descendants.
A separate authenticated GitHub request completed successfully in less than one second.

The request runner waited for stdout/stderr EOF before returning. A terminal forked while a pipe
writer was open could retain it: TerminalSession did not close unrelated descriptors before exec.
The original timeout only terminated a still-running gh process, so it did nothing after gh exited
with an output writer still held elsewhere. The request never returned and loadingRuns stayed true.

A controlled reproduction confirmed the failure: a CLI that exited successfully while a descendant
held its output pipe returned after roughly 1.57 seconds despite a 0.5-second timeout. The descendant
held the pipe for 1.5 seconds; a persistent terminal can keep it open indefinitely.

## Resolution

- Drain both streams without blocking, off the main thread. Finish when the requested process exits,
  collecting its final buffered output without waiting for unrelated writers to produce EOF.
- Keep the existing request timeout, add SIGKILL escalation for children that ignore SIGTERM, and
  bound captured output. Set close-on-exec on request pipes and remove delayed timeout closures.
- Before a PTY child execs its shell, close every nonstandard descriptor using a limit prepared in
  the parent. Only async-signal-safe close/chdir/exec calls run after fork.

The existing GitHubStore completion path now receives either results or a bounded error and clears
the loading flag. No GitHub credentials, repository settings or workflow runs are changed.

## Verification

`bash tools/tests/github-command-tests.sh` covers inherited writers after process exit, full stdout
and stderr, nonzero exit status, SIGTERM resistance, reaping, parallel requests and failed launches.
`bash tools/tests/terminal-child-tests.sh` also checks a high-numbered inherited descriptor (fd 512
when the process limit permits it) while
preserving standard I/O, in addition to its existing termination checks.

Debug app build and focused live GitHub request checks are part of release verification. Native UI
automation was unavailable during diagnosis (its native pipe failed to start), so no claim of a
direct visual check of the Actions panel is made.
