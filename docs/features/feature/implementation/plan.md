---
type: plan
feature: feature
title: Application font size setting
issues:
  - id: I-1
    title: Add and persist the font scale setting
    summary: Add an application-wide font scale preference and a control in Settings. Use 100% by default, with an 80–200% range in 10% steps. Persist it separately from the editor slider, apply it across windows and workspaces, and fall back to 100% when the stored value is missing or invalid. The Settings control and its surrounding text must respond to the selected scale.
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-008, DEC-011]
  - id: I-2
    title: Scale native interface text and AI responses
    summary: Apply the preference to native interface text, including AI responses, Settings, sidebars, labels, and buttons. Scale each text style from its existing base size. At 200%, preserve the selected size and allow wrapping or scrolling where space is limited. Keep document content under its separate size control.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-006, DEC-007, DEC-008]
  - id: I-3
    title: Scale terminal text and refit its grid
    summary: Apply the font scale to terminal text, including AI output displayed there. When glyph size changes, refit the terminal grid and report its new rows and columns to the PTY. Preserve the selected text size and leave line wrapping to normal terminal and program behavior.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-008, DEC-010]
  - id: I-4
    title: Preserve independent document text sizing
    summary: Keep editor, Markdown preview, and code preview document text controlled only by the existing editor slider. Make interface controls around those views follow the application setting. Verify that changing either control leaves the other control’s text domains and stored value unchanged.
    requirements: [REQ-001]
    decisions: [DEC-003, DEC-006, DEC-007, DEC-009]
updated: 2026-09-27
---

# Implementation plan — Общий размер шрифта

## I-1: Add and persist the font scale setting

Add an application-wide font scale preference and a control in Settings. Use 100% by default, with an 80–200% range in 10% steps. Persist it separately from the editor slider, apply it across windows and workspaces, and fall back to 100% when the stored value is missing or invalid. The Settings control and its surrounding text must respond to the selected scale.

Requirements: REQ-001, REQ-003
Decisions: DEC-008, DEC-011

## I-2: Scale native interface text and AI responses

Apply the preference to native interface text, including AI responses, Settings, sidebars, labels, and buttons. Scale each text style from its existing base size. At 200%, preserve the selected size and allow wrapping or scrolling where space is limited. Keep document content under its separate size control.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-006, DEC-007, DEC-008

## I-3: Scale terminal text and refit its grid

Apply the font scale to terminal text, including AI output displayed there. When glyph size changes, refit the terminal grid and report its new rows and columns to the PTY. Preserve the selected text size and leave line wrapping to normal terminal and program behavior.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-008, DEC-010

## I-4: Preserve independent document text sizing

Keep editor, Markdown preview, and code preview document text controlled only by the existing editor slider. Make interface controls around those views follow the application setting. Verify that changing either control leaves the other control’s text domains and stored value unchanged.

Requirements: REQ-001
Decisions: DEC-003, DEC-006, DEC-007, DEC-009
