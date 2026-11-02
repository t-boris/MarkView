---
type: bug
id: BUG-042
title: Project tools write to the window's project and silently ignore a different project_folder
status: fixed
branch: fix/bug-042-project-tools-ignore-project-folder
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
---

# Project tools write to the window's project and silently ignore a different project_folder

## Summary

While fixing BUG-031 from an agent session whose MarkView window had the Butler's repository open, `markview_create_bug`
was called with `project_folder` set to the MarkView checkout. The file `BUG-015-....md` appeared in the Butler's
`docs/bugs/` (a gitignored folder, numbered from that project's own sequence) and nothing was written in MarkView. The call
reported success, so nothing told the agent that the bug had gone to another project.

## Cause

The project tools are served by `MarkView --mcp-project --window <id>`: the server is bound to the window the agent
runs in. `BrowserControlServer.perform` takes that window (`known`) first and uses the folder the agent declares only to
pick a window when none is known (`windowForFolder`). With a bound window a declared `project_folder` was never compared
with the window's project, so a call that named a different project was served by the window's project without a word.

This is what the tool descriptions promise ("writes go to the project of the window you work in, nowhere else"), but the
tool also asks every caller for `project_folder`, so a caller that passes one reasonably expects it to be honoured.

## Resolution

A project tool call whose window is already fixed and whose declared `project_folder` is not that window's project, or a
folder inside it, is refused and nothing is written.

- `BrowserAgentTools.folder(_:isInProject:)` (pure) compares the declared folder with the window's project: equal, or inside
  it, after `~` expansion and symlink resolution (`/var` and `/private/var` are the same place). A name that merely starts
  like the project (`/w/gardening` for `/w/garden`) does not match.
- `BrowserControlServer.perform` applies it to project tools when the agent declared a folder. The reply
  (`BrowserAgentTools.wrongProject`) names both folders, says nothing was done, and points to opening that project in
  a window of its own (`markview_open_project`) or editing its files directly. It does not start with the
  "No MarkView window has the folder" text, so no other running MarkView is asked to serve it.
- The tool instructions say that such a `project_folder` is refused.

Not changed: a call without `project_folder`, and a call whose folder is the window's project or inside it, behave as
before. Browser tools and the control tools (`markview_windows`, `markview_open_project`, ...) are not affected: they do
not write project files.

## Verification

- `bash tools/tests/browser-agent-tools-tests.sh`: the folder rule (own folder, a subfolder, another project, a name prefix,
  a parent, a window without a project, a symlinked spelling, `~`) and the refusal text (names both projects, "Nothing was
  done", not a "no window" reply).
- `bash tools/tests/project-agent-tools-tests.sh` still passes.
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised by a run: a live call from a window of one project naming another. `BrowserControlServer.perform` needs the
  running app with two projects, so the wiring is covered by the build and by reading the call path.
