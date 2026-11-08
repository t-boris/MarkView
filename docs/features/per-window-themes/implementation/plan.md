---
type: plan
feature: per-window-themes
title: Per-Window Themes
issues:
  - id: I-1
    title: Persist independent window theme settings
    summary: Introduce theme and accent state scoped to each workspace window, including restoration across app launches and a remembered default for new windows. Migrate existing users’ light or dark appearance without changing its visible result, and handle missing or invalid settings with a usable fallback. AC-001 through AC-006 are identifiers assigned here to the six acceptance criteria in their listed order.
    requirements: [AC-004, AC-005]
    decisions: []
  - id: I-2
    title: Add the per-window theme and accent picker
    summary: Add a theme picker to each workspace window with System and the four named presets, and make the existing toggle and keyboard shortcut open it. Provide an accent override and reset, remembering overrides separately for each preset and window; returning to a preset restores its override or its default accent. New windows inherit the most recently selected theme and accent settings before becoming independently configurable.
    requirements: [AC-001, AC-003, AC-004]
    decisions: [DEC-001, DEC-002]
  - id: I-3
    title: Define preset design and style native surfaces
    summary: Define coordinated visual tokens for the four presets and apply the selected appearance to MarkView-owned native surfaces in the active window, including controls, focus, selection and semantic status colors. System follows macOS, Paper is light, and the other presets are dark. The proposed palettes and font approach remain unconfirmed and require a design decision before final visual implementation; preserve the separate interface and document text-size controls.
    requirements: [AC-001, AC-002, AC-006]
    decisions: [DEC-001]
  - id: I-4
    title: Theme the editor and Markdown preview
    summary: Propagate each window’s resolved theme and accent to the shipping editor and Markdown preview, including backgrounds, text, controls, syntax highlighting, focus and selections. Apply changes immediately without losing open documents, unsaved edits or panel state, and verify that different windows can display different themes concurrently.
    requirements: [AC-002, AC-006]
    decisions: [DEC-001]
  - id: I-5
    title: Theme discussion and terminal surfaces
    summary: Apply the active window’s resolved theme and accent to discussion and terminal surfaces, including terminal colors and interaction states. Verify immediate updates, legibility and window isolation while preserving active content and panel state.
    requirements: [AC-002, AC-006]
    decisions: [DEC-001]
updated: 2026-11-08
---

# Implementation plan — Per-Window Themes

## I-1: Persist independent window theme settings

Introduce theme and accent state scoped to each workspace window, including restoration across app launches and a remembered default for new windows. Migrate existing users’ light or dark appearance without changing its visible result, and handle missing or invalid settings with a usable fallback. AC-001 through AC-006 are identifiers assigned here to the six acceptance criteria in their listed order.

Requirements: AC-004, AC-005

## I-2: Add the per-window theme and accent picker

Add a theme picker to each workspace window with System and the four named presets, and make the existing toggle and keyboard shortcut open it. Provide an accent override and reset, remembering overrides separately for each preset and window; returning to a preset restores its override or its default accent. New windows inherit the most recently selected theme and accent settings before becoming independently configurable.

Requirements: AC-001, AC-003, AC-004
Decisions: DEC-001, DEC-002

## I-3: Define preset design and style native surfaces

Define coordinated visual tokens for the four presets and apply the selected appearance to MarkView-owned native surfaces in the active window, including controls, focus, selection and semantic status colors. System follows macOS, Paper is light, and the other presets are dark. The proposed palettes and font approach remain unconfirmed and require a design decision before final visual implementation; preserve the separate interface and document text-size controls.

Requirements: AC-001, AC-002, AC-006
Decisions: DEC-001

## I-4: Theme the editor and Markdown preview

Propagate each window’s resolved theme and accent to the shipping editor and Markdown preview, including backgrounds, text, controls, syntax highlighting, focus and selections. Apply changes immediately without losing open documents, unsaved edits or panel state, and verify that different windows can display different themes concurrently.

Requirements: AC-002, AC-006
Decisions: DEC-001

## I-5: Theme discussion and terminal surfaces

Apply the active window’s resolved theme and accent to discussion and terminal surfaces, including terminal colors and interaction states. Verify immediate updates, legibility and window isolation while preserving active content and panel state.

Requirements: AC-002, AC-006
Decisions: DEC-001
