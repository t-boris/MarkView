---
type: bug
id: BUG-109
title: Observed changes review lacks usable diff and explanations
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-08
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Какая версия MarkView установлена? Её можно посмотреть в меню MarkView → About MarkView.
    why: В исходном коде уже есть исправление BUG-107 для размера этого окна; версия поможет понять, попало ли оно в установленное приложение.
    status: answered
    answer: 5.43.0
issue: "#325"
---

# Observed changes review lacks usable diff and explanations

## Summary

The Observed file changes review sheet is reported to be impossible to enlarge and presents before-and-after text without highlighting or explanations, making it difficult to understand individual changes and their impact.

## Steps to reproduce

1. Open a project in MarkView and change a text file after the project has opened.
2. Refresh observed file changes if necessary and click Review in the observed changes bar.
3. Select the modified file.
4. Try to enlarge the review sheet and inspect how the Before and Current versions identify and explain each difference.

## Expected

The comparison should be enlargeable and provide enough space to inspect changes. It should visibly highlight each difference, show where it occurs in the file, and provide an explanation for each change covering why it is a difference and its impact.

## Actual

The user reports that the comparison window cannot be enlarged, does not highlight differences, and provides no explanation of individual changes. The screenshot shows a narrow sheet with a file list and two independently scrolled, heavily wrapped plain-text columns; the visible text does not identify corresponding changes.

## Environment

MarkView for macOS. The supplied screenshot shows Observed file changes with a modified Swift file selected. The app version, macOS version, display size, scaling, and parent window size are unknown.

## Suspected code

- `MarkView/Views/ProjectChangeReviewView.swift` — Presents the sheet, controls its dimensions, and renders the Before and Current columns as separate plain-text scroll views.
- `MarkView/Models/ProjectChangeReview.swift` — Captures and classifies observed file snapshots; inspect it when adding change-level comparison data.
- `MarkView/Views/ContentView.swift` — Hosts the observed changes bar and provides the parent context for the review sheet.
- `docs/bugs/BUG-107-observed-changes-comparison-is-too-narrow.md` — Records a related layout fix in version 5.42.1 and notes that enlargement was measured in an off-screen test but not checked by hand in the installed app.
- `README.md` — Describes Review as a side-by-side diff for observed file changes.

## Likely causes

- The shipping view renders each complete version as plain monospaced SwiftUI Text in a separate ScrollView. The inspected view does not compute or display highlighted change ranges or explanations.
- The review is presented as a SwiftUI sheet. The current source specifies flexible maximum dimensions and says it can be resized, but the reported inability to enlarge it has not been reproduced; its cause or relationship to the installed version is unconfirmed.
- ProjectChangeScanner records before and current snapshots and classifies files as added, modified, or deleted. Those file-level records do not themselves provide per-change explanations.

## Missing information

- The installed MarkView version is needed to determine whether the report predates the BUG-107 layout fix.
- The exact resize gesture and whether enlarging the parent window changes the sheet size are unknown.
- No live reproduction was performed. The exact macOS version and display configuration are unknown.

## Attachments

![assets/BUG-109-pasted-image-E7DCBB95-31DE-45E1-BB03-E2E4A4095293.png](assets/BUG-109-pasted-image-E7DCBB95-31DE-45E1-BB03-E2E4A4095293.png)

## Clarifications

**BQ-1** Какая версия MarkView установлена? Её можно посмотреть в меню MarkView → About MarkView.
→ 5.43.0

## Original description

UI для сравнения это окошко ужасное. Во-первых, его невозможно расширить. Во-вторых, нет хайлайтинга, нет объяснения изменений. Это должно быть нормально, чтобы было объяснение на каждое изменение. То есть я должен запускать потом и показывать тебе разницу. Показывать где в этом файле разница, почему это разница, на что она влияет. А так это совершенно бессмысленное окошко.
