---
type: plan
feature: workspace-folder-name-in-window-title
title: Workspace folder name in window title
issues:
  - id: I-1
    title: Pure window-title formatter with unit tests
    summary: "Add a single pure function (version, folderDisplayName?) -> String that builds 'MarkView <version> — <folder>' with an em dash separator. It omits an empty version and the separator when no folder is open. Display-name resolution (FileManager.displayName(atPath:) with a lastPathComponent fallback) is a small separate helper, so the formatter stays testable. Unit tests cover: folder open, no folder, empty version with and without a folder, the root volume and the fallback when the display name is empty, and that the full path never appears."
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-002, DEC-005, DEC-006]
  - id: I-2
    title: Move title ownership into ContentView and bind it to the workspace root
    summary: "Remove the scene-level .navigationTitle in MarkViewApp.swift:189. In ContentView, apply .navigationTitle computed by the formatter from this window's WorkspaceManager root URL, so every workspace window shows its own folder name and updates on any root change: Open Folder, drag-and-drop, Services/open requests, restore, and closing the folder. Restoring a missing workspace.lastFolder must not open a workspace, so the fallback title shows. Auxiliary windows such as DDE Settings are left unchanged."
    requirements: [REQ-001, REQ-002, REQ-003, REQ-004]
    decisions: [DEC-003, DEC-004, DEC-007, DEC-008]
  - id: I-3
    title: Represented URL (proxy icon) via an NSWindow accessor
    summary: Add a small NSViewRepresentable window accessor in ContentView. It sets NSWindow.representedURL to the workspace root URL and clears it (nil) when no folder is open or the restored folder is missing. It observes the same root state as the title, so the proxy icon and Cmd+click path update together with the title. Same-named folders in different windows can then be told apart by their paths.
    requirements: [REQ-004, REQ-002, REQ-003]
    decisions: [DEC-001, DEC-003, DEC-004, DEC-007]
  - id: I-4
    title: Spec wording updates and manual/UI verification
    summary: "Apply the wording changes the decisions call for: REQ-001 uses the display name and 'each workspace window'; REQ-002 says 'whenever the root changes' and adds criteria for drag-and-drop, closing the folder and restoring a missing lastFolder. Then verify manually or with a UI test: Mission Control, Cmd+` and the Window menu show the same title; two windows with different folders; two windows with same-named folders; the proxy icon appears and is cleared correctly; the DDE Settings title is unchanged."
    requirements: [REQ-001, REQ-002, REQ-003, REQ-004]
    decisions: [DEC-001, DEC-004, DEC-006, DEC-007, DEC-008]
updated: 2026-09-27
---

# Implementation plan — Workspace folder name in window title

## I-1: Pure window-title formatter with unit tests

Add a single pure function (version, folderDisplayName?) -> String that builds 'MarkView <version> — <folder>' with an em dash separator. It omits an empty version and the separator when no folder is open. Display-name resolution (FileManager.displayName(atPath:) with a lastPathComponent fallback) is a small separate helper, so the formatter stays testable. Unit tests cover: folder open, no folder, empty version with and without a folder, the root volume and the fallback when the display name is empty, and that the full path never appears.

Requirements: REQ-001, REQ-003
Decisions: DEC-002, DEC-005, DEC-006

## I-2: Move title ownership into ContentView and bind it to the workspace root

Remove the scene-level .navigationTitle in MarkViewApp.swift:189. In ContentView, apply .navigationTitle computed by the formatter from this window's WorkspaceManager root URL, so every workspace window shows its own folder name and updates on any root change: Open Folder, drag-and-drop, Services/open requests, restore, and closing the folder. Restoring a missing workspace.lastFolder must not open a workspace, so the fallback title shows. Auxiliary windows such as DDE Settings are left unchanged.

Requirements: REQ-001, REQ-002, REQ-003, REQ-004
Decisions: DEC-003, DEC-004, DEC-007, DEC-008

## I-3: Represented URL (proxy icon) via an NSWindow accessor

Add a small NSViewRepresentable window accessor in ContentView. It sets NSWindow.representedURL to the workspace root URL and clears it (nil) when no folder is open or the restored folder is missing. It observes the same root state as the title, so the proxy icon and Cmd+click path update together with the title. Same-named folders in different windows can then be told apart by their paths.

Requirements: REQ-004, REQ-002, REQ-003
Decisions: DEC-001, DEC-003, DEC-004, DEC-007

## I-4: Spec wording updates and manual/UI verification

Apply the wording changes the decisions call for: REQ-001 uses the display name and 'each workspace window'; REQ-002 says 'whenever the root changes' and adds criteria for drag-and-drop, closing the folder and restoring a missing lastFolder. Then verify manually or with a UI test: Mission Control, Cmd+` and the Window menu show the same title; two windows with different folders; two windows with same-named folders; the proxy icon appears and is cleared correctly; the DDE Settings title is unchanged.

Requirements: REQ-001, REQ-002, REQ-003, REQ-004
Decisions: DEC-001, DEC-004, DEC-006, DEC-007, DEC-008
