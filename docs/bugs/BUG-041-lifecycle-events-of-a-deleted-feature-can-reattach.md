---
type: bug
id: BUG-041
title: Lifecycle events of a deleted feature can reattach to a new feature with the same slug
status: open
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
