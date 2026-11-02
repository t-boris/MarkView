---
type: bug
id: BUG-036
title: Operations re-discovery overwrites user edits to fields other than command and working directory
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Operations re-discovery overwrites user edits to fields other than command and working directory

## Summary

`ProjectOperation.isEdited` is true only for user-added operations or when the command or working directory differs from the discovered values. In the Re-discover merge, an operation that is not `isEdited` is replaced wholesale by the new proposal, so a change to its label, kind, environment, target, prerequisites or remote-trigger flag is lost. REQ-007, DEC-004, DEC-027 and DEC-030 require user changes to survive re-discovery. Found by a read-only audit; the merge was read, not run.

## Steps to reproduce

1. Run Discover in the Deployment view so that operations exist in `.markview/operations.json`.
2. Change a discovered operation's label, environment or remote-trigger flag (in the editor, or by hand in the shared file), leaving its command and working directory as they were.
3. Run Re-discover.

## Expected

The changed field keeps the user's value; only discovery metadata (provenance, confidence, discovered values) is refreshed.

## Actual

`document.operations[index] = proposal` replaces the whole entry, so the user's label, environment, kind, target, prerequisites and remote-trigger changes are overwritten. Only command and working-directory edits, user-added operations and tombstones are preserved.

## Environment

MarkView current main (ade7910), MarkView/Models/ProjectOperation.swift (`isEdited`) and MarkView/Models/ProjectOperationsStore.swift lines 443-456; code reading only.
