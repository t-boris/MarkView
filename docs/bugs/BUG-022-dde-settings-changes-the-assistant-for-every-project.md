---
type: bug
id: BUG-022
title: DDE Settings changes the assistant for every project
status: fixed
branch: fix/bug-022-settings-assistant-per-window
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-30
provenance: Reported in a Claude Code session
---

# DDE Settings changes the assistant for every project

## Summary

Boris: "Раздели определение агента по окнам. Когда в одном проекте меняешь модель — она не должна
меняться для остальных проектов." BUG-021 (3.8.0) gave each project its own assistant, model and
X-Ray model, chosen from its window's toolbar. The "Assistant & model" picker in DDE Settings,
opened from a project's window, still edited the global defaults, which every project without its
own choice follows. The single Settings window also stayed bound to the window that opened it first,
so Settings opened from a second window acted on the first window's workspace.

## Steps to reproduce

1. Open two projects that have never chosen their own assistant in two windows.
2. In the first window, open DDE Settings (toolbar assistant menu → "Open AI Settings…", or
   ⌘⇧,) and choose another model.
3. The second window's toolbar, AI terminal and AI requests switch to that model too.

## Expected

The model chosen in a project's window, in the toolbar or in Settings, applies to that project
only. Other projects keep theirs.

## Actual

The Settings picker wrote `settings.cli.<tool>Model` and `settings.ai.backend`, the defaults, so
every project without its own choice changed. On this machine, `project.ai` held choices for only
two projects while the defaults had been edited several times: the changes went through Settings.

## Root cause

`AIAssistantPickerView` bound the default keys with `@AppStorage` instead of the window's project
through `AssistantChoice`, and `DDESettingsWindow.show(workspace:)` reused the window it had built
for the first workspace without rebinding it to the workspace that asked for it.

## Resolution

- `AIAssistantPickerView` takes the window's project and edits it through `AssistantChoice`, as the
  toolbar menu does; without a project (a single file, the welcome screen) it edits the defaults.
  It refreshes when any choice changes, so it shows the toolbar's changes and vice versa.
- DDE Settings names the project it edits ("Assistant & model for <project>") and says that other
  projects keep theirs; without a project it says it sets the defaults.
- `DDESettingsWindow.show(workspace:)` rebinds the single Settings window to the workspace that
  opens it and puts the project in the title.

The per-project storage and resolution (`ProjectAIChoice`, `AIAssistantPreferences.backend(project:)`,
`model(for:project:)`) are unchanged; `tools/tests/project-ai-choice-tests.sh` still covers them.

## Environment

MarkView 3.11.0 on macOS with several project windows open.
