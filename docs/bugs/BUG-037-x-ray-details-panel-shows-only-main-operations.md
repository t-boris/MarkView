---
type: bug
id: BUG-037
title: X-Ray details panel shows only "Main operations" instead of listing every operation
status: open
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# X-Ray details panel shows only "Main operations" instead of listing every operation

## Summary

With no node selected, the Deployment details panel lists a short "Main operations" group and hides the rest behind "Show all N" or a search box, with no grouping by kind. REQ-010 and DEC-009 say the panel lists every project operation, grouped by kind. Either the code or the requirement should change; this bug records the mismatch. Found by a read-only audit.

## Steps to reproduce

1. Open the project X-Ray, Deployment view, in a project with more than five discovered operations.
2. Select no node and look at the details panel.

## Expected

Every operation is listed, grouped by kind (REQ-010 acceptance criteria).

## Actual

A "Main operations" heading with a short list; the remaining operations appear only after pressing "Show all N", and there are no kind headings.

## Environment

MarkView current main (ade7910), MarkView/Resources/Editor/vendor/js/markview-architecture.js around lines 1461-1489; code reading only.
