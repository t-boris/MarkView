---
type: plan
feature: feature-2
title: Project color identification (feature-2)
issues:
  - id: I-1
    title: Store persistent colors by project identity
    summary: Implement a local project color store keyed by the standardized folder path after resolving symbolic links. Define the eight palette values, choose an initial color using a stable hash, persist assignments and user overrides, and allow different projects to share a color. Verify that assignments and overrides survive relaunch.
    requirements: [REQ-001]
    decisions: [DEC-002, DEC-008, DEC-009]
  - id: I-2
    title: Add the project icon and color picker
    summary: Add a clickable project-colored icon beside the project name in windows with an open project folder. Clicking it opens a picker using the defined palette. Keep the text name readable, preserve the existing folder proxy icon and window controls, and show no project color cue in windows without a project folder.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-003, DEC-005, DEC-007, DEC-012]
  - id: I-3
    title: Verify the color cue during window switching
    summary: Make the project color recognizable in Mission Control window thumbnails on macOS 13 and later. Verify the icon in the window and in Mission Control at realistic window sizes; because the title bar icon is too small in thumbnails, also show a 3 pt band in the project color directly below the toolbar (DEC-013), keeping the project name and controls usable.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-004, DEC-006, DEC-007, DEC-013]
  - id: I-4
    title: Synchronize colors across project windows
    summary: Update every open window for a project immediately when its color changes. Recompute the displayed color when a window changes folders and when a saved window session is restored. Verify that two windows showing the same folder remain consistent and that windows without a project folder show no cue.
    requirements: [REQ-001]
    decisions: [DEC-001, DEC-008, DEC-010]
updated: 2026-09-28
---

# Implementation plan — Цветовая идентификация проектов

## I-1: Store persistent colors by project identity

Implement a local project color store keyed by the standardized folder path after resolving symbolic links. Define the eight palette values, choose an initial color using a stable hash, persist assignments and user overrides, and allow different projects to share a color. Verify that assignments and overrides survive relaunch.

Requirements: REQ-001
Decisions: DEC-002, DEC-008, DEC-009

## I-2: Add the project icon and color picker

Add a clickable project-colored icon beside the project name in windows with an open project folder. Clicking it opens a picker using the defined palette. Keep the text name readable, preserve the existing folder proxy icon and window controls, and show no project color cue in windows without a project folder.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-003, DEC-005, DEC-007, DEC-012

## I-3: Verify the color cue during window switching

Make the project color recognizable in Mission Control window thumbnails on macOS 13 and later. Verify the icon in the window and in Mission Control at realistic window sizes; because the title bar icon is too small in thumbnails, also show a 3 pt band in the project color directly below the toolbar (DEC-013), keeping the project name and controls usable.

Requirements: REQ-001, REQ-002
Decisions: DEC-004, DEC-006, DEC-007, DEC-013

## I-4: Synchronize colors across project windows

Update every open window for a project immediately when its color changes. Recompute the displayed color when a window changes folders and when a saved window session is restored. Verify that two windows showing the same folder remain consistent and that windows without a project folder show no cue.

Requirements: REQ-001
Decisions: DEC-001, DEC-008, DEC-010
