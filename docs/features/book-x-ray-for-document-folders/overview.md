---
type: feature
id: book-x-ray-for-document-folders
title: Book X-Ray for document folders
status: implemented
owner: Boris Tsekinovsky
created: 2026-09-30
provenance: Created from a Claude Code session (planning interview, four decisions)
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: n/a
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
understanding_notes:
  Problem: The documents X-Ray showed folders and files with flat H1/H2 sections and document-level links; nothing said what a section contains.
  Target Users: Boris reading a project's or folder's documentation in MarkView.
  Primary Workflow: Open the X-Ray of a folder, switch to Book, read the chapter blurbs, open a chapter's sections, double-click a section to read it.
  Permissions: Not applicable.
  Failure Scenarios: No text documents (empty state); the AI answers badly (retry once, keep the skeleton); long chapters (windows); documents without headings (AI sections).
  Data Model: Book view nodes root/dir/doc/section/items with line, endLine, anchor; edges links and related; importance ratings.
  Notifications: Not applicable.
  Security: Documents are sent to the configured X-Ray assistant as before; nothing new leaves the machine.
  Analytics: Not applicable.
  Dependencies: ArchitectureScanner, ArchitectureStore, XRayContent, the X-Ray web view.
  Acceptance Criteria: See Scope and the harness tools/tests/book-xray-tests.sh.
questions_left: 0
---

# Book X-Ray for document folders

## Idea

The X-Ray of a folder of documents works like a book assembled from all its folders: parts
(folders), chapters (documents), sections (headings, nested), and cross-references between
them. A reader drills down to a section and opens the document right there; every chapter and
section carries a short annotation of what it says, so the whole documentation can be read
through at a glance. Large documents, in any text format, break down further into the items
their sections are made of before the document is opened.

## Problem

The documents X-Ray ("Docs") listed folders, files and flat H1/H2 sections with document-level
link arrows and no descriptions. It did not help answer the question that matters most: where
in this documentation is the thing I need to understand, and what does it say.

## Scope

In: the Book view for the project X-Ray and every folder X-Ray; a deterministic skeleton
(`BookBuilder`) from Markdown, `.txt`, `.rst`, `.adoc` and `.org` documents; links resolved to
the section (inline, reference-style, wiki, `xref:`, RST targets); AI annotations for every
chapter and section during Analyze, cached by content, with importance, related sections and
items of large chapters; "Describe this chapter" / "Describe remaining chapters"; opening a
section at its line; the panel with lineage and cross-references; nested section ranges in the
⚡ filters and searches.

Out: a single file's X-Ray (a file keeps Explain); AI reorganisation of the structure (chapters
follow the folders and files); HTML as chapters; a separate book-like layout outside the graph.

## Decisions

- DEC-001 Skeleton from the structure, the AI writes texts.
- DEC-002 Annotations for all sections at Analyze, cached by content.
- DEC-003 Cross-references: links in the text plus AI-inferred related sections.
- DEC-004 Folders only; a single file keeps today's behaviour.

## Implementation

Version 3.12.0, branch `feat/book-xray`. Module reference:
`docs/architecture/modules/architecture-and-xray.md` §5.11. Checks:
`tools/tests/book-xray-tests.sh`.
