---
type: plan
feature: pdf-reading-in-markview
title: Integrated read-only PDF reader
issues:
  - id: I-1
    github: 274
    status: implementing
    title: Open PDFs in dedicated, read-only workspace tabs
    summary: Add PDF document classification and route workspace file opening to a dedicated reader tab instead of text loading. Reopening the same file must select its existing tab. Integrate the reader into the workspace without modifying source PDFs or providing saved highlights and notes. Preserve existing PDF export and feature-source ingestion; opening a PDF must not initiate AI processing or add its contents to workspace search.
    requirements: [REQ-001]
    decisions: [DEC-001, DEC-002, DEC-003]
  - id: I-2
    github: 275
    status: implementing
    title: Render complete PDFs and provide essential reading controls
    summary: Render every page in its original order for text-based, scanned, and mixed-content PDFs. Provide scrolling, zoom, fit-to-page, fit-to-width, current page and page count, and direct page navigation. Verify navigation from first to last page and readable rendering of image-only pages without offering or running OCR.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001, DEC-002, DEC-003]
  - id: I-3
    github: 276
    status: implementing
    title: Navigate PDFs through thumbnails and document outlines
    summary: Display selectable page thumbnails that navigate to their corresponding pages. When a document contains an outline, display its hierarchy and support navigation to its destinations. Verify both navigation mechanisms in multipage documents and ensure documents without outlines remain fully readable.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001]
  - id: I-4
    github: 277
    status: implementing
    title: Search, select, and copy existing PDF text
    summary: "Provide in-document search across pages with navigation to matching content, plus text selection and copying where document permissions permit. Use existing text layers only: image-only pages must not yield recognized text, while mixed documents retain text interactions wherever embedded text is available. Verify these behaviors without changing existing feature-source text extraction."
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-001, DEC-002, DEC-003]
  - id: I-5
    github: 278
    status: implementing
    title: Follow PDF links using existing URL-safety conventions
    summary: Support internal PDF links that navigate to destinations within the current document and external links handled according to the application's applicable URL-safety conventions. Inspect and reuse existing boundary validation rather than treating PDF-provided URLs as trusted. Verify internal destination navigation and permitted external-link activation without enabling document editing.
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-001]
updated: 2026-11-03
---

# Implementation plan — PDF Reading in MarkView

## Checkpoint: implementation started

- Baseline: `origin/main` at `da4fe17`; local `main` fast-forwarded to the same commit.
- Branch: `feat/pdf-reading-in-markview`, isolated in `.worktrees/feat-pdf-reading`.
- All fourteen original specification files were read before implementation.
- GitHub work: [I-1 #274](https://github.com/t-boris/MarkView/issues/274),
  [I-2 #275](https://github.com/t-boris/MarkView/issues/275),
  [I-3 #276](https://github.com/t-boris/MarkView/issues/276),
  [I-4 #277](https://github.com/t-boris/MarkView/issues/277),
  [I-5 #278](https://github.com/t-boris/MarkView/issues/278). All remain open until merge.
- DEC-001's stale consequences were corrected exactly as DEC-003 and F-001 require.
- Existing unrelated worktrees are preserved and excluded from this feature's commits.
- No stakeholder answers were added or changed. The unrelated-worktree question could not
  receive an answer in unattended mode; preservation is the non-destructive default.

## I-1: Open PDFs in dedicated, read-only workspace tabs

Add PDF document classification and route workspace file opening to a dedicated reader tab instead of text loading. Reopening the same file must select its existing tab. Integrate the reader into the workspace without modifying source PDFs or providing saved highlights and notes. Preserve existing PDF export and feature-source ingestion; opening a PDF must not initiate AI processing or add its contents to workspace search.

Requirements: REQ-001
Decisions: DEC-001, DEC-002, DEC-003

## I-2: Render complete PDFs and provide essential reading controls

Render every page in its original order for text-based, scanned, and mixed-content PDFs. Provide scrolling, zoom, fit-to-page, fit-to-width, current page and page count, and direct page navigation. Verify navigation from first to last page and readable rendering of image-only pages without offering or running OCR.

Requirements: REQ-001, REQ-002
Decisions: DEC-001, DEC-002, DEC-003

## I-3: Navigate PDFs through thumbnails and document outlines

Display selectable page thumbnails that navigate to their corresponding pages. When a document contains an outline, display its hierarchy and support navigation to its destinations. Verify both navigation mechanisms in multipage documents and ensure documents without outlines remain fully readable.

Requirements: REQ-001, REQ-002
Decisions: DEC-001

## I-4: Search, select, and copy existing PDF text

Provide in-document search across pages with navigation to matching content, plus text selection and copying where document permissions permit. Use existing text layers only: image-only pages must not yield recognized text, while mixed documents retain text interactions wherever embedded text is available. Verify these behaviors without changing existing feature-source text extraction.

Requirements: REQ-001, REQ-003
Decisions: DEC-001, DEC-002, DEC-003

## I-5: Follow PDF links using existing URL-safety conventions

Support internal PDF links that navigate to destinations within the current document and external links handled according to the application's applicable URL-safety conventions. Inspect and reuse existing boundary validation rather than treating PDF-provided URLs as trusted. Verify internal destination navigation and permitted external-link activation without enabling document editing.

Requirements: REQ-001, REQ-003
Decisions: DEC-001
