---
type: bug
id: BUG-087
title: UI Studio opens on the built-in scenario, so data the person asked the AI to add looks lost
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# UI Studio opens on the built-in scenario, so data the person asked the AI to add looks lost

## Summary

A context change ("add 16 strikes up and down") is saved as a scenario file in .markview/studio/scenarios/ and made active, but a new UI Studio session always starts on the built-in Populated preset. The saved scenario waits in the Scenario menu, so on reopening the data appears to be gone, and the person asks again; each ask saves another scenario (broker-fabric has two identical 33-strike scenarios, saved at 14:01 and 15:12).

## Steps to reproduce

1. Open UI Studio for a project and ask the AI to add data (a context change). It is applied and saved as a scenario.
2. Close UI Studio and open it again for the same application.

## Expected

The application opens on the scenario the person ended on, with the data they asked for; asking again builds on it.

## Actual

The application opens on the built-in Populated scenario without the added data; the saved scenario has to be found in the Scenario menu.

## Environment

MarkView 5.27.0. The session's init() always takes presets[0]; nothing records which scenario was active.
