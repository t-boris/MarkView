---
type: bug
id: BUG-019
title: Completed AI progress cards accumulate in Tasks
status: fixed
branch: fix/issue-workflows
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Когда завершённая карточка должна исчезать?
    why: Это определит правило автоматической очистки; сейчас срок хранения не задан.
    options:
      - label: Сразу после завершения
        text: Убирать карточку сразу после завершения операции.
      - label: Через короткое время
        text: Показывать итог недолго, затем убирать автоматически.
      - label: При следующем запуске
        text: Сохранять карточку до закрытия приложения, при новом запуске очищать.
    status: answered
    answer: Сразу после завершения. Убирать карточку сразу после завершения операции.
  - id: BQ-2
    text: Ошибочные и остановленные операции тоже должны исчезать автоматически?
    why: Их карточки могут содержать ошибку или неполный ответ, которые пользователь ещё не прочитал.
    options:
      - label: Только успешные
        text: Автоматически убирать только успешно завершённые карточки.
      - label: Все завершённые
        text: Автоматически убирать успешные, ошибочные и остановленные карточки.
    status: answered
    answer: Только успешные. Автоматически убирать только успешно завершённые карточки.
issue: "#74"
---

# Completed AI progress cards accumulate in Tasks

## Summary

Successfully completed AI progress cards accumulate in Tasks instead of disappearing immediately, as clarified in BQ-1.

## Steps to reproduce

1. Open a workspace with a feature or bug report.
2. Start an Intake, Bug investigation, or other AI action that displays progress in Tasks.
3. Wait for the action to complete successfully.
4. Observe that the completed card remains; repeat to see cards accumulate.

## Expected

Remove a successfully completed AI progress card immediately when its operation finishes. Generated feature and bug documents remain available.

## Actual

After an AI action finishes, its status card remains in Tasks with a manual dismiss button. Repeated actions accumulate cards during the app session.

## Environment

MarkView native macOS app (macOS 13+, SwiftUI). App and macOS versions were not provided.

## Suspected code

- `MarkView/Models/FeatureAI.swift` — The successful completion path sets phase to completed and retains the entry in actions; removal occurs only through dismissAction.
- `MarkView/Views/FeaturePanelView.swift` — actionProgress renders all entries in assistant.actions and provides manual dismissal for finished entries.
- `MarkView/Views/TOCView.swift` — Routes the Tasks tab to FeaturePanelView, confirming the affected surface.

## Likely causes

- FeatureAssistant changes an action's phase to completed but leaves it in the actions dictionary.
- FeaturePanelView renders every stored action and shows a dismiss button for finished cards.

## Missing information

- Whether failed and stopped cards should also disappear automatically remains open (BQ-2). This does not block fixing successful completion.
- The report does not establish whether cards survive an app relaunch; the inspected action collection is held in memory.

## Clarifications

**BQ-1** Когда завершённая карточка должна исчезать?
→ Сразу после завершения. Убирать карточку сразу после завершения операции.

**BQ-2** Ошибочные и остановленные операции тоже должны исчезать автоматически?
→ Только успешные. Автоматически убирать только успешно завершённые карточки.

## Original description

В панели Task появляются Intake, Bug, и вот такие вот результаты прогресс работы AI. Это неплохо, но не храни их. Старые должны уходить сами, то есть я не должен их удалять.
