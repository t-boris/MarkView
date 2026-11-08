---
type: bug
id: BUG-107
title: Observed changes comparison is too narrow
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-08
provenance: Created from the bug intake
issue: "#315"
---

# Observed changes comparison is too narrow

## Summary

The side-by-side comparison in the Observed file changes review sheet is too narrow to read comfortably because the file list consumes a large portion of the sheet.

## Steps to reproduce

1. Open a project in MarkView.
2. After the project opens, delete a Markdown file containing several lines of text outside or inside the app.
3. Refresh observed file changes if needed, then click Review.
4. Select the deleted file and inspect the Before and Current columns.

## Expected

The Before and Current versions have enough horizontal space to read and compare content comfortably, including when a file is deleted.

## Actual

In the supplied screenshot, the file list occupies approximately half of the review sheet, leaving each comparison column only about a quarter of the sheet. The Before text wraps heavily, making it difficult to read and compare.

## Environment

MarkView on macOS. The screenshot shows the Observed file changes sheet with a deleted Markdown file selected. App version, macOS version, window dimensions, and display scaling are unknown.

## Suspected code

- `MarkView/Views/ProjectChangeReviewView.swift` — Defines the review sheet, the file list's minimum and ideal widths, the sheet's minimum width, and the equally expanding Before and Current columns.
- `MarkView/Views/ContentView.swift` — Hosts ProjectChangeReviewBar, the entry point that opens the review sheet; useful for checking available parent window context.
- `README.md` — Documents Review as a side-by-side diff for observed file changes, establishing the intended review workflow.

## Likely causes

- Likely layout cause: the file list and comparison share an HStack without an explicit width allocation that prioritizes the comparison.
- The sheet specifies a minimum width of 680 points but no larger preferred width. The two versions then share the remaining comparison area equally.

## Missing information

- The exact application and macOS versions, window dimensions, and display scaling are unknown.
- It is unknown whether the same width problem occurs for added and modified files or at larger window sizes.

## Attachments

![assets/BUG-107-pasted-image-4E2F571D-8C2D-4021-99E0-4A0B2644893F.png](assets/BUG-107-pasted-image-4E2F571D-8C2D-4021-99E0-4A0B2644893F.png)

## Original description

Look at attachment the Compare is too narrow - FIX
