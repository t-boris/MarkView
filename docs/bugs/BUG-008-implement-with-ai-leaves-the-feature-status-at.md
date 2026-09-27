---
type: bug
id: BUG-008
title: "\"Implement with AI\" leaves the feature status at \"review\" and doesn't record that implementation started"
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где вы нажали Implement with AI?
    why: Кнопки в двух местах, и от места может зависеть, найдётся ли slug фичи.
    options:
      - label: Панель фичи
        text: Кнопка в Feature panel
      - label: Дерево файлов
        text: Контекстное меню в file tree
    status: answered
    answer: Панель фичи. Кнопка в Feature panel
  - id: BQ-2
    text: Появилось ли позже в истории фичи событие 'implementation started'?
    why: Так станет ясно, запаздывает ли событие или не записывается совсем.
    options:
      - label: Да, позже
        text: Появилось с задержкой
      - label: Нет
        text: Так и не появилось
      - label: Не смотрел
        text: Не проверял
    status: answered
    answer: Нет. Так и не появилось
  - id: BQ-3
    text: Какой статус должна получить фича после нажатия?
    why: В коде не нашлось, какой статус эта кнопка должна ставить.
    options:
      - label: implementing
        text: Отдельный статус implementing
      - label: in_progress
        text: Статус in_progress
    status: answered
    answer: implementing. Отдельный статус implementing
  - id: BQ-4
    text: Какой ИИ-бэкенд был выбран, когда вы нажали Implement with AI?
    why: Событие «implementation started» записывается только после того, как найден лог сессии CLI. Как искать этот лог, зависит от бэкенда. Ответ покажет, где именно запись пропала.
    options:
      - label: Claude
        text: Claude Code CLI
      - label: Codex
        text: Codex CLI
      - label: Не знаю
        text: Не помню или не знаю
    status: answered
    answer: Claude. Claude Code CLI
issue: "#29"
---

# "Implement with AI" leaves the feature status at "review" and doesn't record that implementation started

## Summary

Clicking "Implement with AI" in the Feature panel sends the implement prompt to the AI assistant (Claude Code CLI), and the assistant starts implementing. The feature's front-matter status stays 'review', and the 'implementation started' lifecycle event is never recorded, even much later (BQ-2). implementWithAI never writes a status. It relies on a detached task that polls the Claude Code CLI session log to record implementationStarted, and that task fails silently. The workflow spec only allows the move into `implementing` through createIssues. The user decided the status after the click must be `implementing` (BQ-3).

## Steps to reproduce

1. Open a project with a feature whose front-matter status is 'review'.
2. Select Claude (Claude Code CLI) as the AI backend.
3. Open the feature in the Feature panel and click 'Implement with AI' without using 'Create issues' first.
4. Watch the assistant start implementing in the Terminal tab.
5. Check the feature status in the Feature panel, the file tree and the issue listing.
6. Check the feature's lifecycle history, including after more than 15 minutes.

## Expected

Right after the click (once the prompt has been sent to the assistant), the feature's front-matter status changes to `implementing` (BQ-3). The new status shows everywhere in the UI. The 'implementation started' lifecycle event is recorded immediately and reliably, whether or not the Claude Code session log is found. Failures are logged, not swallowed.

## Actual

The status stays 'review' everywhere. The 'implementation started' event is never recorded, even after the assistant has been working for a long time (confirmed by the user).

## Environment

MarkView macOS app (Darwin 27.0.0). Triggered from the 'Implement with AI' button in the Feature panel. AI backend: Claude Code CLI (BQ-4).

## Suspected code

- `MarkView/Models/WorkspaceManager.swift` — implementWithAI (~line 3264) sends the prompt but never sets the `implementing` status. By contrast, fixBugWithAI calls updateBug to set 'fixing'. implementWithAI also returns early without recording anything if the slug lookup fails or if sendToAssistant/profile.tool returns nil.
- `MarkView/Models/FeatureStore.swift` — recordImplementationStarted (~lines 610-636) writes the event from Task.detached, and only after answeringModel finishes polling the Claude Code session log (up to 15 min). If polling fails or times out, nothing is recorded and nothing is logged. observeLifecycle only reacts to status changes, so it cannot back-fill the event.
- `MarkView/Views/FeaturePanelView.swift` — This is the 'Implement with AI' button (~line 1250). The move to `implementing` is tied only to 'Create issues' (~line 1285).
- `docs/architecture/modules/feature-workflow.md` — The state diagram only enters `implementing` through createIssues. It needs a review→implementing transition on Implement with AI.

## Likely causes

- implementWithAI has no step that updates the status. The spec only moves a feature to `implementing` through createIssues.
- The implementationStarted event depends on a detached task that must find the Claude Code session log. If polling fails, times out, looks in the wrong session directory or file, or the app quits, the event is lost silently.
- implementWithAI returns early without recording anything when the slug lookup fails or when sendToAssistant/profile.tool returns nil.

## Missing information

- It is not confirmed why the Claude Code session-log polling failed (wrong path, a timeout or a lost task). This needs app logs or a debug run.

## Clarifications

**BQ-1** Где вы нажали Implement with AI?
→ Панель фичи. Кнопка в Feature panel

**BQ-2** Появилось ли позже в истории фичи событие 'implementation started'?
→ Нет. Так и не появилось

**BQ-3** Какой статус должна получить фича после нажатия?
→ implementing. Отдельный статус implementing

**BQ-4** Какой ИИ-бэкенд был выбран, когда вы нажали Implement with AI?
→ Claude. Claude Code CLI

## Original description

Вот фичу я нажал Implement with AI, он стал имплементировать, но почему-то статус пишет эту фичу Review, то есть Start Implementation он нигде не зафиксировал. По-моему это баг.
