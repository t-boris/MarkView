---
type: feature
id: pdf-reading-in-markview
title: PDF Reading in MarkView
status: done
delivery_status: blocked
delivery_blocker: F-002
owner: t-boris
created: 2026-11-03
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
understanding_notes:
  Problem: The requested outcome is integrated PDF reading, not editing, conversion, or export changes.
  Target Users: MarkView users who need to read PDF documents inside the app; no distinct user roles are required.
  Primary Workflow: Open a PDF in a tab, navigate its pages, and use the accepted reading controls. Workspace search and new AI workflows are excluded.
  Permissions: The project runs without App Sandbox. The native reader enforces copying restrictions, makes forms read-only and supports password unlocking without storing passwords.
  Failure Scenarios: Unreadable, malformed, missing, empty and locked documents have explicit states covered by automated native checks; no additional product decision is needed.
  Data Model: Reading is read-only, with no saved highlights or notes. WorkspaceManager already reuses tabs for the same file.
  Notifications: No background OCR or new notification workflow is included.
  Security: Existing project rules require boundary validation and protection of document contents; external PDF links must follow applicable URL-safety conventions.
  Analytics: No analytics capability is requested.
  Dependencies: FeatureIngest.swift already uses PDFKit for page-by-page embedded-text extraction without OCR. Reader implementation choices belong to the implementer.
  Acceptance Criteria: Complete read-only reading controls are accepted; scans render without OCR, and search and copying depend on existing text layers. No further stakeholder questions are needed.
questions_left: 0
---

# PDF Reading in MarkView

## Idea

Add integrated PDF reading to MarkView so users can open and read PDF documents inside the app.

## Problem

MarkView supports PDF export and PDF text extraction for feature sources, but its document-opening workflow has no dedicated PDF reader. The agreed scope is a complete read-only PDF reader; reader OCR and new PDF integration with workspace search or AI are excluded from this release.

## Scope

Confirmed: opening and reading PDFs inside MarkView, including multipage documents, with essential reading controls, thumbnails, document outlines when present, in-document text search, text selection and copying, and internal and external links. Scanned pages are displayed without OCR; search, selection, and copying use existing text layers only. Saved highlights and notes are outside this release's reader scope. New PDF integration with workspace search or AI is excluded from this release; existing PDF feature-source ingestion remains unchanged. PDF editing, conversion, and changes to existing PDF export are not established by this request.

## Baseline behaviour before this implementation

- FileType and TabKind have no dedicated PDF case. Regular files are openable regardless of extension; unknown formats fall back to text loading, which rejects binary content or unsupported encodings. (`MarkView/Models/DocumentState.swift`)
- openFile reuses existing tabs and routes archives, data files, and images to dedicated viewers. Other files are attempted as text. Text-reading failures offer opening the file in the default application. (`MarkView/Models/WorkspaceManager.swift`)
- The workspace already hosts dedicated image, archive, browser, and other tab views alongside the editor, but has no dedicated PDF reader view. (`MarkView/Views/ContentView.swift`)
- File → Open File uses an unrestricted file picker and passes the selected file to WorkspaceManager; PDF selection is not prevented by the picker. (`MarkView/App/MarkViewApp.swift`)
- Feature-source ingestion already extracts embedded PDF text page by page using PDFKit. This extraction path does not perform OCR. (`MarkView/Models/FeatureIngest.swift`)
- The browser can save pages as PDFs; opening a downloaded PDF explicitly delegates to the macOS default application. (`MarkView/Views/BrowserTabView.swift`)
- Documented PDF capabilities include document export and PDF-book export with linked contents, page numbers, and bookmarks. These are export capabilities, not an integrated reader. (`README.md`)

## Implementation

The dedicated native PDF reader is implemented in `Models/PDFReader.swift` and
`Views/PDFReaderView.swift`. PDF tabs retain their reader state, bypass the text
editor and saving/indexing paths, and restore with the window session. DEC-004
records technical boundary and failure handling choices without reopening any
answered product question. See `implementation/plan.md` for current task status,
GitHub issues and verification checkpoints. `implementation/verification.md`
maps every acceptance criterion to implementation and automated evidence.
Release prerequisite finding F-002 blocks signed publication and deployment; verified
implementation status is not a claim that the full delivery objective is complete.
