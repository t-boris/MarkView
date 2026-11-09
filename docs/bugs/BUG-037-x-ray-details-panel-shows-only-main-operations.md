---
type: bug
id: BUG-037
title: X-Ray details panel shows only "Main operations" instead of listing every operation
status: done
branch: fix/bug-037-operations-list-by-kind
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

## Cause

The panel was changed on purpose to a different design than the approved requirement, and the requirement was never updated.

- REQ-010 (approved 2026-09-29) and DEC-009 say: with no node selected, every project operation is listed, grouped by
  kind; with a node selected, its related operations come first and all others follow. No operation is hidden.
- Commit 894ee5a (3.7.0, the same day) rewrote `renderOperations` in `markview-architecture.js`: up to five "main"
  operations chosen by `ProjectOperation.primary` (running, recently started, then by kind), and every other operation
  behind a search field and a "Show all N" toggle (hidden by default). The rest were sorted by kind but had no kind
  headings. No requirement or decision records this change.

## Resolution

Boris decided that the code follows the specification, not the other way round. REQ-010 and DEC-009 are unchanged.

In `renderOperations` (`markview-architecture.js`):

- With no node selected, every operation is listed under a heading per kind, in a fixed order: deploy, install, build,
  restart, clean, other (the kinds the operations file allows). A kind outside that list, which the current file format
  rejects but a newer one might add, follows them by name, so no operation can be dropped. Inside a group, operations
  are ordered by label. The order depends only on kind and label, so it does not change when a run starts or ends.
- With a node selected, the DEC-009 behaviour is kept: "Related to <node>" first, highlighted, then every other
  operation grouped by kind. A related operation is not repeated in a kind group, so a group heading counts only the
  operations listed under it.
- Removed: the "Main operations" list, the "All operations (N)" heading, the "Show all N" / "Hide the list" toggle,
  and the search field with its saved query and focus state (`operationQuery`, `operationsShowAll`,
  `operationSearchFocused`). The search field only existed to reach operations the toggle hid. REQ-010 and DEC-018
  describe no search, and keeping it would have needed extra code to hide group headings with no match. If Boris wants
  it back, it is a separate change.

## Not changed

- REQ-010, DEC-009, DEC-027 and DEC-018 (the Deploy button picker, which has its own grouping by environment).
- Each operation card: name, environment and kind, the confidence, running and "Remote trigger" marks, "Outside
  project", Run or Open output, Last run, Edit, Adopt discovered, and the message when the operations file or the
  working directory is unavailable. The empty-state text ("No runnable procedure is known for this project.") and
  the order of the sections under the list (Add operation, Re-discover, discovery report).
- How a related node is resolved (by node id, then by exact node name; an unresolved relation is ignored).
- Swift side. The app still sends `primary` in the operations payload (`ProjectOperationsStore.primaryOperations`,
  `ProjectOperation.primary`, `tools/tests/project-operation-primary-tests.sh`), but nothing reads it any more. Removing
  it is a separate cleanup and was not done here.

## Verification

- `bash tools/tests/code-architecture-tests.sh` passes, 0 failures in both parts. Ten new checks in
  `tools/tests/CodeArchitectureWebTests.swift` drive the shipped `index.html` and `markview-architecture.js` in headless
  WebKit with ten operations (kinds deploy x3, install, build x2, restart, clean, other, and one unknown kind), five of
  them "primary" in the payload:
  - no node selected: one heading per kind in the fixed order, the unknown kind last; all ten operations visible once;
    operations inside a kind ordered by label; no "Main operations", no "Show all" toggle, no search field;
  - running, remote-trigger and low-confidence marks, Run (nine) and Open output (one) are present;
  - node selected: "Related to api" first with one highlighted operation, then the other nine by kind; a relation
    whose node id is gone resolves by node name; a node with no related operation highlights nothing and still lists
    all ten; a relation to an unknown node is ignored;
  - no operations: the empty-state text shows and no kind heading.
  The same checks run against the previous `markview-architecture.js` give 9 failures (only the five primary
  operations visible, a "Main operations" heading, a toggle and a search field).
- Rendered the panel in the same headless WebKit page and looked at a screenshot and the text dump: kind headings in
  capitals ("DEPLOY (3)", "INSTALL (1)", ...), cards unchanged, with and without a node selected.
- `node --check` on the edited script passes. `project-operation-primary-tests.sh`, `structure-reveal-tests.sh` and
  `book-pdf-tests.sh` still pass. Debug build with `xcodebuild` (see CLAUDE.md) passes, and the built app bundle
  contains the edited script.
- Not exercised by a run: the real app. The page was fed a hand-made payload (a three-node Deployment view and
  invented operations), not a real project's `.markview/operations.json`, and the Cytoscape graph beside the panel was
  not part of the check. Whether a long list scrolls comfortably in the real details panel was not tried by hand.
