---
type: bug
id: BUG-130
title: Copilot stops a whole run at a discovery QA step that the QA runner could not click through
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: BUG-129
schema: 1
---

# Copilot stops a whole run at a discovery QA step that the QA runner could not click through

## Summary

A 20-step Cockpit run in vivaa-platform (run CF9C64A9, 2026-11-25) stopped at step 3, a non-prerequisite QA step on Development, and waited a day until the person ended it. Three causes: (1) the QA runner's page snapshot lists only semantic controls and an [onclick] attribute, so a React row that opens with a mouse click (<tr onClick>) is invisible and the QA branch ends blocked/elementNotFound; (2) the Temporal workflow pauses the run on every failed step, although the planner is told that only a prerequisite's failure pauses later steps, so the fix steps 4–6 never ran; (3) the pause showed the agent's 4,150-character report with "blocked" at its end and no needed input, and the QA-filed bugs (BUG-717…727 in vivaa) were not carried into the step.

## Steps to reproduce

1. Approve a Cockpit plan whose step 3 runs a QA scenario (qaScenarioID) and is not a prerequisite, with later steps meant to fix what QA finds
2. In the app under test, the QA branch must open an item whose only opener is a React onClick on a table row (vivaa admin, Vendor applications, apps/admin-panel/components/masters/applications-tab.tsx:111)
3. Start the run and let the QA runner reach that node

## Expected

The QA runner can click whatever a person can click with the mouse (and records that the element opens only with the mouse); a failed step that is not a prerequisite is recorded and the run goes on to the next step; a failed QA step says where and why QA stopped and which bugs it filed, and those bug ids reach the step result.

## Actual

QA verdict blocked/elementNotFound at node n3 ("В списке нет доступного элемента для открытия заявки A"); step 3 failed; the run paused with only Retry step / Open Plan / End (a retry would block at the same row); the run was ended by the person 24 hours later; progress.bugs was empty although QA filed BUG-717 (blocked) and BUG-718…727 (defects).

## Environment

MarkView 7.7.1; project vivaa-platform; Cockpit run .dde/cockpit/runs/CF9C64A9-5AAC-4EF3-87CE-3902BDAD8AC2.json; QA run .dde/qa/runs/20261125-234853-977e; code: MarkView/Models/Browser/BrowserAgentExecutor.swift:426 (snapshot selector), MarkView/Models/Cockpit/CockpitQAAttempt.swift:85, tools/cockpit-temporal/workflow.go:312, MarkView/Models/Cockpit/CockpitPlanning.swift:22
