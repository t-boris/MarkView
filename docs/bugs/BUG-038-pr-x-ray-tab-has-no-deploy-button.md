---
type: bug
id: BUG-038
title: PR X-Ray tab has no Deploy button and no project operations
status: open
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# PR X-Ray tab has no Deploy button and no project operations

## Summary

The pull-request X-Ray tab shows the project's architecture (its scope maps to the project store), but every `operation*` bridge handler in `WorkspaceManager` is guarded by `scope.isEmpty`, so the tab cannot start or list operations. The feature overview says the Deploy button appears in every view of the project X-Ray. It is not certain that the PR tab counts as such a view, so the intended behaviour should be confirmed before fixing. Found by a read-only audit.

## Steps to reproduce

1. Open a project that has discovered deploy operations.
2. Open the PR X-Ray tab and look for the Deploy control.
3. Compare with the project X-Ray tab.

## Expected

Either the PR X-Ray offers the same Deploy control as the project X-Ray, or the specification states that it does not.

## Actual

No operations UI works on the PR tab: the bridge ignores operation messages whose scope is the pull-request scope.

## Environment

MarkView current main (ade7910), MarkView/Models/WorkspaceManager.swift lines 1491, 1512 and 1651-1659; code reading only.
