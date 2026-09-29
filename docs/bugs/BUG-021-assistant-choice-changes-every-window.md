---
type: bug
id: BUG-021
title: Choosing the assistant in one window changes it in every window
status: fixed
branch: fix/bug-021-assistant-per-project
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Reported in a Claude Code session
---

# Choosing the assistant in one window changes it in every window

## Summary

The toolbar's assistant, model and X-Ray model were global settings. Changing them in one window
changed every open window, restarted AI terminals in other projects, and redirected their
background AI work (X-Ray, operations discovery, research).

## Steps to reproduce

1. Open two projects in two windows.
2. In the first window, switch the toolbar assistant from Claude Code to Codex.
3. The second window's toolbar and AI terminal switch to Codex too.

## Expected

Each project keeps its own assistant, model and X-Ray model. A change affects only the windows
and AI work of that project.

## Actual

All windows and all AI requests followed one global value.

## Root cause

`AIAssistantPreferences.backend`, `model(for:)` and `xrayModel(for:)` read global `UserDefaults`,
and `CLICompletion.Request.tool` defaulted to the global backend. The toolbar menus and the AI
terminal panel bound the same keys with `@AppStorage`, so a change in one window fired in all.

## Resolution

- `ProjectAIChoice` stores a project's own assistant, models and X-Ray models under its project
  key (`ProjectColor.projectKey`) in local settings. What a project has not chosen comes from the
  defaults, which DDE Settings edits.
- Every read names its project: `backend(project:)`, `model(for:project:)`,
  `xrayModel(for:project:)`. `CLICompletion.Request` requires `project`, so all request sites
  state which project they work for; `tool` is the project's assistant unless set explicitly.
- X-Ray (including folder X-Rays, which belong to the window's project), Explain, code navigation,
  research, features, operations discovery, GitHub failure explanations, Recursive Insight,
  translation, selection actions and the AI terminal use the window's project.
- The toolbar menus edit the window's project (or the defaults for a single file). The AI terminal
  restarts only when its own project's choice changes.

`tools/tests/project-ai-choice-tests.sh` covers defaults, per-project isolation, path spelling,
requests, empty values and windows without a project.

## Environment

MarkView 3.7.0 on macOS with several project windows open.
