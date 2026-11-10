---
type: bug
id: BUG-122
title: QA run is blocked at the baseline, so the test-account step is never reached
status: backlog
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-10
provenance: Created by an AI agent through MarkView
related: end-to-end-qa
---

# QA run is blocked at the baseline, so the test-account step is never reached

## Summary

Every run of the vivaa scenario ends "Blocked: the baseline could not be established" before any player is signed in or a test account is created, because the generated baseline asks for an operator-level action (restore a snapshot) that the page driver cannot do.

## Steps to reproduce

1. Open the generated scenario 'Client requests an event package; fairy reviews and follows up when needed' on dev.vivaa.ai
2. Both players have 'Test account' on; the Baseline section says to restore an approved snapshot of an isolated environment with existing client and fairy accounts and that the person supplies logins
3. Choose a branch and run it

## Expected

The run signs the players in or creates their test accounts and plays the branch, or tells the person before the run which preparation only a person can do and lets them confirm it.

## Actual

Four runs (2026-11-10 09:24 to 09:34) were all Blocked in 16 seconds or less at the baseline: "Baseline restoration requires an operator-supplied approved isolated environment and snapshot restore mechanism". The runner hands the baseline text to the assistant that drives the page (QARunner.runSetup), which has no such control, so it refuses. Account creation (QARunner after the baseline) never ran. The baseline text also contradicts the players' 'Test account' setting (it assumes existing accounts and supplied logins).</actual>
<parameter name="environment">MarkView 5.58.0, dev.vivaa.ai, project vivaa-platform

## Environment

Unknown
