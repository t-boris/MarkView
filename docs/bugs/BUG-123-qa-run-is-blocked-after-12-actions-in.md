---
type: bug
id: BUG-123
title: QA run is blocked after 12 actions in a step that was making progress
status: in-progress
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-10
provenance: Created by an AI agent through MarkView
related: BUG-122
---

# QA run is blocked after 12 actions in a step that was making progress

## Summary

A fixed budget of 12 actions per step ends a step as Blocked ("The step was not completed within 12 actions.") even when every action moves it forward. The run 20261110-135136-7901 on dev.vivaa.ai was creating the Client's test account (open sign-in, open the sign-up form, name, e-mail, password, confirm password, Create account, wait, open Account, wait) and was cut at the twelfth action, one look away from finishing. A long form, a multi-page flow or a slow page needs more than 12 actions, so the limit blocks valid scenarios. The only thing a limit is needed for is a step that goes in circles.

## Steps to reproduce

1. Run a scenario whose player has createTestAccount on an application with a sign-up form of four or more fields
2. The assistant fills the form and presses Create account
3. After the twelfth action the step is Blocked with "The step was not completed within 12 actions."

## Expected

A step goes on while it makes progress. It is given up only when it goes in circles: the same action chosen again and again on a page that does not change.

## Actual

Blocked after 12 actions, 0 steps of the scenario run. The timeline shows 12 sensible actions, none repeated, the last ones waiting for the new account and opening Account to check the sign-in.

## Environment

MarkView 5.60.0, QARunner.Config.maxActionsPerStep = 12, dev.vivaa.ai
