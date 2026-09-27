---
type: plan
feature: new-research-repository-grounded-analysis
title: "New Research: repository-grounded analysis"
issues:
  - id: I-1
    title: Research document template, front-matter and storage path
    summary: "Define the research document format and its persistence layer. The template has YAML front-matter (type: research, id, question, created, status, web_queries) and fixed sections: Question, Summary, Findings with label prefixes, Recommendations and Sources. It also defines the incomplete callout and the follow-up delimiter. Files are written to docs/research/<YYYY-MM-DD>-<slug>.md with numeric-suffix collision handling, and the folder is created on first use. A validator checks the labels and required citations. Research documents are recognised only by front-matter type: research, independent of path."
    requirements: [REQ-003, REQ-004]
    decisions: [DEC-006, DEC-007, DEC-008]
  - id: I-2
    title: New Research intake dialog and menu entry points
    summary: Add 'New Research' as a separate item in every New… entry point, with prompt text that distinguishes it from I Need to Understand, which stays unchanged. The dialog takes a free-text question, an optional Target documents list pre-filled with the open document, attachments, and an editable output path pre-filled per DEC-006. The Deep Research item in the AI Tools menu is redirected to this dialog, and the old 'research' prompt is retired.
    requirements: [REQ-001]
    decisions: [DEC-001, DEC-009, DEC-010, DEC-006]
  - id: I-3
    title: Background research agent job with progress and cancellation
    summary: "Run research as a cancellable, headless background agent job (Claude Code) with the prompt passed via a file. The agent uses tool-based search and file reads over the analysis scope: git-tracked text files that honour .gitignore, excluding binary, generated and vendor files and files over 1 MB. Target documents are always included. Docs-only and empty repositories are supported; an empty repository yields a Summary stating that no project facts were available. On completion the document is written and opened. On failure or cancellation a partial document is saved, marked incomplete and states what failed."
    requirements: [REQ-002, REQ-003]
    decisions: [DEC-012, DEC-016, DEC-004, DEC-002]
  - id: I-4
    title: "Research prompt: fact/inference labelling and web search guardrails"
    summary: "Write the research prompt so it enforces the DEC-008 template. It must require exactly one of the four labels on every finding, repository path citations for project facts and URLs for external facts, and the AI-inference label for model knowledge without a verifiable source. The AI may use web search at its own discretion, with guardrails: queries are sanitised (no code, secrets or internal names), each query is logged in front-matter web_queries, and a per-repository opt-out is available. If web search is unavailable, the run falls back to repository-only research marked incomplete."
    requirements: [REQ-004, REQ-002]
    decisions: [DEC-003, DEC-011, DEC-008, DEC-004]
  - id: I-5
    title: "'Continue / deepen' follow-ups and retry of incomplete parts"
    summary: "Show a 'Continue / deepen' action on any opened document with type: research. Before starting, the user is prompted to save or cancel if there are unsaved edits. The current on-disk document is sent to the AI as context. The job re-reads the file and appends a dated '## Follow-up N' section after '---' without rewriting earlier content or the user's edits. When the latest section is incomplete, 'Retry incomplete part' is pre-selected. Once every incomplete section has a successful retry, the front-matter status becomes complete; this is the only mutation allowed to existing content. A failed follow-up appends a section marked incomplete."
    requirements: [REQ-003]
    decisions: [DEC-002, DEC-005, DEC-013, DEC-014, DEC-004, DEC-007]
  - id: I-6
    title: Comments that revise the commented section
    summary: "In a type: research document, the editor selection menu offers 'Revise With Comment'. The AI gets the whole document, the smallest enclosing section, the selected passage and the comment, and returns the revised section. The app replaces that section only if it is unchanged on disk, applies the REQ-004 label check and records web queries. Failure or cancel leaves the file unchanged."
    requirements: [REQ-005]
    decisions: [DEC-017]
updated: 2026-09-27
---

# Implementation plan — New Research: repository-grounded analysis

## I-1: Research document template, front-matter and storage path

Define the research document format and its persistence layer. The template has YAML front-matter (type: research, id, question, created, status, web_queries) and fixed sections: Question, Summary, Findings with label prefixes, Recommendations and Sources. It also defines the incomplete callout and the follow-up delimiter. Files are written to docs/research/<YYYY-MM-DD>-<slug>.md with numeric-suffix collision handling, and the folder is created on first use. A validator checks the labels and required citations. Research documents are recognised only by front-matter type: research, independent of path.

Requirements: REQ-003, REQ-004
Decisions: DEC-006, DEC-007, DEC-008

## I-2: New Research intake dialog and menu entry points

Add 'New Research' as a separate item in every New… entry point, with prompt text that distinguishes it from I Need to Understand, which stays unchanged. The dialog takes a free-text question, an optional Target documents list pre-filled with the open document, attachments, and an editable output path pre-filled per DEC-006. The Deep Research item in the AI Tools menu is redirected to this dialog, and the old 'research' prompt is retired.

Requirements: REQ-001
Decisions: DEC-001, DEC-009, DEC-010, DEC-006

## I-3: Background research agent job with progress and cancellation

Run research as a cancellable, headless background agent job (Claude Code) with the prompt passed via a file. The agent uses tool-based search and file reads over the analysis scope: git-tracked text files that honour .gitignore, excluding binary, generated and vendor files and files over 1 MB. Target documents are always included. Docs-only and empty repositories are supported; an empty repository yields a Summary stating that no project facts were available. On completion the document is written and opened. On failure or cancellation a partial document is saved, marked incomplete and states what failed.

Requirements: REQ-002, REQ-003
Decisions: DEC-012, DEC-016, DEC-004, DEC-002

## I-4: Research prompt: fact/inference labelling and web search guardrails

Write the research prompt so it enforces the DEC-008 template. It must require exactly one of the four labels on every finding, repository path citations for project facts and URLs for external facts, and the AI-inference label for model knowledge without a verifiable source. The AI may use web search at its own discretion, with guardrails: queries are sanitised (no code, secrets or internal names), each query is logged in front-matter web_queries, and a per-repository opt-out is available. If web search is unavailable, the run falls back to repository-only research marked incomplete.

Requirements: REQ-004, REQ-002
Decisions: DEC-003, DEC-011, DEC-008, DEC-004

## I-5: 'Continue / deepen' follow-ups and retry of incomplete parts

Show a 'Continue / deepen' action on any opened document with type: research. Before starting, the user is prompted to save or cancel if there are unsaved edits. The current on-disk document is sent to the AI as context. The job re-reads the file and appends a dated '## Follow-up N' section after '---' without rewriting earlier content or the user's edits. When the latest section is incomplete, 'Retry incomplete part' is pre-selected. Once every incomplete section has a successful retry, the front-matter status becomes complete; this is the only mutation allowed to existing content. A failed follow-up appends a section marked incomplete.

Requirements: REQ-003
Decisions: DEC-002, DEC-005, DEC-013, DEC-014, DEC-004, DEC-007

## I-6: Comments that revise the commented section

In a type: research document, the editor selection menu offers 'Revise With Comment'. The AI gets the whole document, the smallest enclosing section, the selected passage and the comment, and returns the revised section. The app replaces that section only if it is unchanged on disk, applies the REQ-004 label check and records web queries. Failure or cancel leaves the file unchanged.

Requirements: REQ-005
Decisions: DEC-017
