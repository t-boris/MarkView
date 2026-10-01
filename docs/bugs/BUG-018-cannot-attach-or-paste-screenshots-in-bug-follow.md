---
type: bug
id: BUG-018
title: Cannot attach or paste screenshots in bug follow-up
status: fixed
branch: fix/issue-workflows
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где и как вы пытались добавить скриншот?
    why: Это уточнит точные шаги воспроизведения и покажет, касается ли сбой вставки изображения или отсутствия элемента для вложений.
    options:
      - label: Только нет кнопки
        text: Я не пробовал вставлять через ⌘V; не нашёл способ прикрепить файл.
      - label: ⌘V не сработало
        text: Я попробовал вставить скриншот в поле ответа через ⌘V, но изображение не добавилось.
      - label: Другое место
        text: Я пытался добавить изображение в другом месте обсуждения бага.
    status: answered
    answer: Только нет кнопки. Я не пробовал вставлять через ⌘V; не нашёл способ прикрепить файл.
issue: "#72"
---

# Cannot attach or paste screenshots in bug follow-up

## Summary

Existing-bug follow-up has no visible way to attach a screenshot when the AI asks for one. The reporter specifically could not find an attachment button and did not test ⌘V. Code inspection confirms that bug question answers accept text only, while file attachment and image paste support exist in the separate New Bug intake.

## Steps to reproduce

1. Create or open a bug with an open AI question.
2. Open the bug in the Feature tab and find its question answer field.
3. Look for a control to attach an image file while answering the question.
4. Observe that the question card offers text answers and answer buttons, but no file attachment control.

## Expected

While answering an AI question about an existing bug, the user can attach an image file or paste a screenshot. The image stays associated with that bug and is available during AI investigation.

## Actual

The reporter could not find a button to attach a screenshot while discussing an existing bug. They did not try ⌘V, so clipboard paste failure is unverified. Code inspection shows a text-only answer field and no attachment control in the bug question card; the behavior was not reproduced in a running app.

## Environment

MarkView native macOS app (macOS 13+), Feature tab for an existing bug with an AI question. Reporter app build and macOS version are unknown.

## Suspected code

- `MarkView/Views/FeaturePanelView.swift` — BugQuestionCard renders a plain TextField and answer buttons, with no attachment picker, preview, or image-aware paste view; it calls answerBug with text only.
- `MarkView/Models/FeatureIntake.swift` — answerBug accepts only a URL, question ID, and String answer, then records text in Clarifications. newBug has attachment copying and prompt references, but follow-up does not.
- `MarkView/Views/FeatureNavigatorView.swift` — The New Bug intake sheet provides Add Files, attachment state, and an IntakeTextEditor with image paste guidance; this UI is separate from existing-bug follow-up.
- `MarkView/Views/IntakeTextEditor.swift` — AttachmentTextView converts pasted images into attachment URLs, but BugQuestionCard does not use it.
- `docs/architecture/modules/feature-workflow.md` — The documented workflow describes attachments at bug creation and question rounds during investigation, but no follow-up attachment flow.

## Likely causes

- BugQuestionCard provides a plain TextField and sends only a String answer.
- answerBug records text in Clarifications and has no path to copy, reference, or provide follow-up attachments to the investigation.
- The image-aware editor and file picker are used by New Bug intake, but are not wired into bug follow-up.

## Missing information

- The reporter's app build and macOS version are unknown; these are not needed to locate the missing attachment path.
- Clipboard behavior in the follow-up field remains untested by the reporter. The code has no image-aware paste or attachment handling there.
- The screenshot source and format are unknown; they are not needed to identify the missing file attachment control.

## Clarifications

**BQ-1** Где и как вы пытались добавить скриншот?
→ Только нет кнопки. Я не пробовал вставлять через ⌘V; не нашёл способ прикрепить файл.

## Original description

Когда я в багах обсуждаю баг, так сказать, у меня нет возможности добавить картинку, хотя он иногда просит, чтобы я прислал какие-нибудь снапшаты. У меня даже нет возможности добавить никакой снапшат или лучше всего копипейст, чтобы срабатывать.
