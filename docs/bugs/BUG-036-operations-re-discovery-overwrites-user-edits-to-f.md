---
type: bug
id: BUG-036
title: Operations re-discovery overwrites user edits to fields other than command and working directory
status: done
branch: fix/bug-036-operations-rediscovery-edits
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

## Cause

The audit finding was right, and the loss was wider than the report listed.

- `ProjectOperation.isEdited` compares only `command` and `cwd` with `discovered`, and `discovered` held nothing
  else. For every other editable field the file had no record of what discovery had proposed, so a user edit could
  not be told from discovery output.
- The Re-discover merge (`discover`) and the accept-proposal merge (`acceptProposal`) both kept an operation only
  when `isEdited`; any other operation was replaced by the proposal with `document.operations[index] = proposal`.
- The replacement also dropped the stored entry's `extra`. That is where the editor records `nodesEdited`, so a
  changed deployment node was lost too, and so was any field written by a newer MarkView.

Confirmed by running the previous rule against the new checks: label, kind, environment, target, prerequisites,
remote-trigger and deployment-node edits are all replaced (see Verification).

## Resolution

Each operation now carries a record of the other editable fields as discovery last proposed them, and "the user
changed something" is derived by comparing every editable field with that record.

- `.markview/operations.json` gains one optional key per operation, `discoveredFields` (label, kind, environment,
  target, prerequisites, remoteTrigger). Discovery writes it next to `discovered` (command, cwd), which is
  unchanged. A missing `environment` or `target` inside it means discovery proposed none.
- `ProjectOperation.hasUserChanges(comparedTo:)` is true when command, working directory, label, kind,
  environment, target, prerequisites or remote-trigger flag differ from `discovered` / `discoveredFields`, or when
  the editor's `nodesEdited` marker is set.
- `ProjectOperation.merged(stored:proposal:)` is the single merge decision, used by Re-discover and by accepting a
  proposal. A deleted or user-added operation is returned as it is. An operation without user changes is replaced
  by the proposal (unknown fields of the stored entry are carried over). An operation with any user change keeps
  every value it has and only discovery metadata is refreshed: `discovered`, `discoveredFields`, `provenance`,
  `confidence`, and the deployment node relations unless the user set them (DEC-027). If discovery now proposes a
  different command for such an operation, the existing "Discovery suggests" row and "Adopt discovered" action
  show it (DEC-017).
- An operation written by an earlier version has no `discoveredFields`. Whether a field differs because the user
  edited it or because discovery changed cannot be known, so a difference is treated as a user edit and the stored
  value is kept. The proposal is recorded as the new snapshot, so later runs compare correctly.
- Stored layout and compatibility: the file `version` stays 1 and no existing key changes. A file written before
  the fix is saved back byte for byte (the key is omitted when there is no snapshot). An older MarkView reads the
  new key as an unknown field, keeps it in `extra` and writes it back unchanged when it saves (checked, see
  Verification). A damaged `discoveredFields` is read as "not recorded" instead of making the file unreadable.
  The record sits beside `discovered` and not inside it because the older `Discovered` type has no `extra`, so an
  older MarkView would have dropped new keys inside it on every save.

## Not changed

- `ProjectOperation.isEdited` keeps its meaning (command or working directory is the user's). The confidence text,
  the external-source warning in the run confirmation and the "Adopt discovered" action depend on exactly that, and
  a renamed label must not silence them.
- The granularity is the operation, as in REQ-007 ("update only operations the user has not changed"): once any
  field is the user's, the command is not refreshed automatically either. The user sees the new suggestion and
  adopts it. Refreshing the untouched fields one by one was rejected because it can pair a user-chosen
  environment or kind with a command discovered for something else.
- A hand edit of `nodes` in the file is still not noticed; the marker exists only for edits made in the editor.
- Operation matching by id, kind/environment/target and command (DEC-017 item 5) is untouched: an operation whose
  kind, environment or target the user changed may still be proposed again as a new entry if the assistant does
  not reuse its id.
- "Adopt discovered" still adopts only command and working directory.
- DEC-017 still describes `discovered` as the only snapshot; it was not edited. No version bump (left to the
  release step).

## Verification

- `bash tools/tests/project-operation-merge-tests.sh` (new, 69 checks, all pass):
  - an untouched operation is refreshed in every field, and unknown stored fields are carried over;
  - each single edit is kept: label, kind, environment set and cleared, target set and cleared, prerequisites
    changed and cleared, remote-trigger flag, command, working directory, deployment node. For each, the check also
    requires that discovery metadata is refreshed and that nothing else in the operation changes;
  - an edit undone by hand counts as untouched again, and an edit survives a second run;
  - user-added operations and deleted operations (with or without an edit) are returned untouched;
  - operations with no recorded snapshot: nothing differs gives a refresh and a recorded snapshot, a difference is
    kept;
  - file layout: a file without the new key is saved back byte for byte, the new key is written once per operation
    and is not mistaken for an unknown field, unknown fields survive, a damaged snapshot still reads, and a
    Re-discover over a file (edited, untouched, user-added, deleted and new operations) writes the expected result.
  - The same checks run against a copy of the previous rule and 29 of them fail, so they can see the bug.
- `bash tools/tests/project-operation-primary-tests.sh` and `zsh tools/tests/project-operation-discovery-tests.sh`
  pass. The primary test's `AnyCodable` stand-in moved to `tools/tests/ProjectOperationAnyCodableStub.swift`
  (a faithful copy, shared with the new test) because the model now reads `extra["nodesEdited"]`.
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Older-version round trip, run once and not kept as a script: the previous `ProjectOperation.swift` (from main
  before this change) was compiled on its own, read a file in the new layout, changed a label and saved. The
  output still held `discoveredFields` unchanged, and the new model then read it back and treated the label as a
  user edit.
- Not exercised: a real Re-discover with an assistant (the check mirrors the store's merge loop inside
  `ProjectOperationsFile.mutate` but does not run `ProjectOperationsStore`), the editor and the run
  confirmation in the running app, and the accept-proposal alert. Their Swift code is covered by the build and by
  reading the call path.
