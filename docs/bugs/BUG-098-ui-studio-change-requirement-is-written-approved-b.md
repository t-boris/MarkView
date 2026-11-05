---
type: bug
id: BUG-098
title: UI Studio change requirement is written approved, but REQ-012 says it is marked implemented
status: open
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
updated: 2026-11-05
---

# UI Studio change requirement is written approved, but REQ-012 says it is marked implemented

## Summary

REQ-012 criterion 2 says each applied UI Studio change is a requirement of the conversation's feature "and is marked implemented". The tracking writer produces an approved requirement (the check `REQ-012 a change is an approved requirement with its request, element, scope, files, checks and patch` asserts exactly that), so the record and the criterion disagree. Either the status written is wrong, or DEC-008 and the criterion should say approved. It needs a decision on which one is meant before changing code: an applied change is already in the code, so `implemented` is what the requirement lifecycle would show for it.

## Steps to reproduce

1. Apply any change in a UI Studio conversation so that a feature and a requirement are created.
2. Open the requirement under docs/features/<conversation feature>/requirements/ and read its status.
3. Compare with REQ-012 criterion 2 of markview-ui-studio.

## Expected

The requirement of an applied change shows the status the criterion names (implemented), or the criterion and DEC-008 are corrected to the status that is actually intended.

## Actual

The requirement is written as approved. The criterion stays unticked for this reason only; the rest of REQ-012 (feature per conversation, bug for a repair, Undo marks reverted, Switch) is covered by 36 passing checks.

## Environment

MarkView 5.35.0, `MarkView/Models/UIStudioTracking.swift` and the tracking checks in `tools/tests/UIStudioSessionHarness.swift`. Feature markview-ui-studio, REQ-012 criterion 2, DEC-008.
