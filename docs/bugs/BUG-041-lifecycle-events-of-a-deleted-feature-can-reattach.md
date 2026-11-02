---
type: bug
id: BUG-041
title: Lifecycle events of a deleted feature can reattach to a new feature with the same slug
status: fixed
branch: fix/bug-041-lifecycle-reused-slug
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Lifecycle events of a deleted feature can reattach to a new feature with the same slug

## Summary

Lifecycle events are stored and looked up by project and feature slug. `FeatureStore.deleteFeature` moves the feature folder to the Trash but does not remove its events. If a new feature later gets the same slug, the old events show up in its timeline and cycle-time statistics. DEC-012 of the lifecycle feature says events of deleted features are not shown. Found by a read-only audit; slug reuse after deletion was not exercised.

## Steps to reproduce

1. Create a feature, so that it gets an `idea_created` event, then delete it (move it to the Trash).
2. Create another feature whose title produces the same slug.
3. Open the lifecycle timeline of the new feature.

## Expected

The new feature's timeline starts empty (only its own `idea_created` event).

## Actual

By code reading, `LifecycleLog.events(project:feature:)` filters on slug alone and nothing purges the deleted feature's events, so they reappear.

## Environment

MarkView current main (ade7910), MarkView/Models/FeatureStore.swift `deleteFeature` (line 400) and MarkView/Models/LifecycleLog.swift line 41; code reading only.

## Cause

The slug can be given out again, and the log is read by slug alone.

- `FeatureStore.createFeature` picks a slug from the title and only checks that the folder
  `docs/features/<slug>` does not exist (it appends `-2`, `-3` for folders that do). `deleteFeature` moves that
  folder to the Trash, so the slug is free again and a new feature with the same title gets it. Confirmed by reading
  both functions; no run was needed to see it.
- The deleted feature's events stay in `lifecycle-events.jsonl`, by design (REQ-001, DEC-005, DEC-012: the log is
  append-only, deleting a feature leaves its events in storage).
- Two readers looked events up by project and slug only. `LifecycleLog.events(project:feature:)` fed the timeline,
  the "mark stage" sheet and the project tool. The cycle-time summary did not use it at all: `CycleTimeSummarySheet`
  read `events(project:)` and grouped by slug itself, so a fix in the per-feature accessor alone would have left the
  statistics wrong.
- The same accessor is read by the automatic capture, so an old `spec_ready` could have suppressed the new feature's
  "handed to implementation" fallback, an old manual `implementation_started` could have set the date from which
  GitHub captures are followed, and old pull-request notes could have deduplicated the new feature's captures.

## Resolution

History starts at the latest `idea_created`, decided in one place on the reading side. The log file and its
append-only API are untouched.

- `LifecycleAnalytics.currentHistory(_:)` (pure, Foundation only) takes the events of one project and slug in the
  order they were recorded and returns them from the last `idea_created` on. Earlier events belong to an earlier
  feature that had the slug. Recording order is used, not timestamps, so a backdated automatic stamp or a moved clock
  cannot move the cut. `LifecycleAnalytics.histories(_:)` does the same for every slug of a project.
- `LifecycleLog.events(project:feature:)` goes through `currentHistory`. `LifecycleLog.histories(project:)` replaces
  `events(project:)`, which had no other caller, so no reader can skip the cut.
- `CycleTimeSummarySheet` takes its per-feature events from `histories(project:)` and keeps its existing filter to the
  features that still exist.
- A feature with no `idea_created` event (created on another machine or before the log existed, DEC-012) keeps all of
  its events.

## Not changed

- The log file, its append-only API and the old events: they stay in the file, only the feature-level readers skip
  them.
- Slug allocation in `createFeature`: it still hands out the slug of a trashed feature. Avoiding that would change
  folder names and could not know about events of features deleted earlier or elsewhere.
- A feature that takes the slug of a deleted one without going through `createFeature` (folder added by an editor, git
  or an AI agent, so no `idea_created` is recorded) still shows the older feature's events. The log holds nothing that
  tells the two apart; a stable feature id would (DEC-012 already names it as a later option).
- DEC-012 and the other decisions: their text already says events of deleted features are not shown, which now also
  holds when the slug is reused.

## Verification

- `tools/tests/lifecycle-tests.sh`: 92 checks pass, 21 of them new:
  - reused slug: older events are ignored, steps and total are measured from the new idea, the old `verified` event
    gives the new feature no total, a slug reused twice counts only from the last idea, events recorded after the cut
    stay even with an earlier timestamp;
  - a normal feature keeps every event and its total; no events give no history;
  - a feature with no `idea_created` keeps all of its events;
  - per project: a reused slug does not touch other features, and the cycle-time summary counts it from its new idea
    only.
  With the cut disabled, 10 of the reuse checks fail (the normal and imported cases pass either way, as they should).
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised by a run: the real flow in the app (create a feature, delete it, create one with the same title, open
  its Lifecycle section and the cycle-time sheet). `LifecycleLog` itself and the SwiftUI sheet cannot be compiled by the
  standalone test, so their use of `currentHistory` and `histories` is covered by the build and by reading the call
  path only. No real `lifecycle-events.jsonl` was read.
