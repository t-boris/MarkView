---
type: bug
id: BUG-106
title: "Delivery evidence: the oldest commit of a shallow clone counts as code work (its files are the whole tree), so a documentation record blocks fixed"
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-07
provenance: Created by an AI agent through MarkView
related: BUG-104
---

# Delivery evidence: the oldest commit of a shallow clone counts as code work (its files are the whole tree), so a documentation record blocks fixed

## Summary

An agent working in /Users/boris/github.com/vivaa-platform asked for BUG-091 fixing -> fixed. MarkView refused: "commit f0209a9: this project requires a merged pull request" and "commit f0209a9 has no workflow run, so its checks are unknown", although PR #772 (merge commit 5b38dfa31, which names BUG-091 in its title and description) was merged with passing checks and released as v1.187.1.

Root cause (reproduced with the real IssueEvidenceCollector against the real repository, git and gh really executed): the local clone is shallow (.git/shallow lists f0209a9, depth 2). Git cannot see the parent of f0209a9, so `git log --name-only` lists every file of its tree (5633 files, 914,043 lines) as added. f0209a9 is only the documentation record of 2026-11-05..07 (8 files under docs/), but the collector drops documentation-only commits by their paths, so it kept this one as code work. Its message names BUG-091, so it became a work unit that is a direct commit on main: no pull request, no workflow run. The evaluator then reports both gaps. PR #772 is judged correctly, but one unmet unit makes the whole verdict incomplete. With a clone that shows the parent (depth 6) the same collector answers complete(PR #772 merged, checks passed).

The agent's reading (the record commit was taken for work and cannot meet the condition) is right; the reason is the shallow boundary, not the commit being old. Linking #772 changes nothing because the commit is matched by its message.

## Steps to reproduce

1. Clone a GitHub project with `git clone --depth 2` (or use an agent's shallow checkout), so that the oldest visible commit is a documentation-only commit naming a bug.
2. Merge a pull request that names the bug, with passing checks.
3. Ask for the bug's status to become fixed (markview_set_bug_status) or open markview_issue_context.

## Expected

A documentation-only commit is not implementation work whether or not the clone is shallow. The verdict for BUG-091 is complete(PR #772 merged, checks passed). When the files of a boundary commit cannot be read at all (no GitHub), the verdict says so (unknown) instead of treating its whole tree as changed.

## Actual

incomplete(missing: [\"commit f0209a9: this project requires a merged pull request\", \"commit f0209a9 has no workflow run, so its checks are unknown\"])

## Environment

MarkView 5.37.3 installed; the collector on main (5.39.2) gives the same verdict in a live run. Project vivaa-platform (VIVAA-Events/platform), `.git/shallow` = f0209a94a93354b2246cab2035d8627b43c383bc.

## Fix (v5.39.3, PR #310, merge 4e79ae8)

- `IssueEvidenceCollector` reads `.git/shallow`. For every boundary commit on the log it asks GitHub which files the commit changed
  (`gh api --paginate repos/<slug>/commits/<sha> --jq .files[].filename`; sha and slug validated; 3000 files or more count as unreadable).
  Without an answer the commit's files are unknown (`GitWorkLog.Commit.pathsUnknown`), not the whole tree.
- `DeliveryEvaluator`: a unit whose files are unknown is only reported as unreadable (verdict `unknown`); it adds no definite
  "requires a merged pull request" or "no workflow run" gap.
- Live run on the real shallow `vivaa-platform` clone, BUG-091: `incomplete` (old) -> `complete(summary: ["PR #772 merged, checks passed, in release v1.187.1"])`.
- Checks: a `git clone --depth 2` scenario in `tools/tests/IssueCollectorChecks.swift` (4 checks fail on the old collector) and three
  evaluator checks in `IssueEvidenceChecks.swift` (2 fail on the old evaluator). All lifecycle suites pass.

Not changed on purpose: a shallow clone whose log is shorter than the 400-commit window still reports that the window reaches back to the start
of a reopened issue. That can hide work, but it ends in "no merged implementation work", never in a false `complete`.

Open: BUG-091 stays `fixing` until the installed app is 5.39.3 and the agent asks again (only the installed app can record `fixed`).

