---
type: bug
id: BUG-034
title: "\"I Need to Understand\" runs gh pr list while the GitHub integration is off"
status: open
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
