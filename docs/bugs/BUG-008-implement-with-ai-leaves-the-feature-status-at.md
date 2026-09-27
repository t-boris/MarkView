---
type: bug
id: BUG-008
title: "\"Implement with AI\" leaves the feature status at \"review\" and doesn't record that implementation started"
status: fixed
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

The Feature panel's `Implement with AI` action starts Claude Code CLI work but leaves the feature at `review`. The user chose `implementing` as the required status. The `implementationStarted` event was also absent later. Code confirms the missing status update; the lifecycle failure needs a debug trace because polling has a fallback after 15 minutes.

## Steps to reproduce

1. Open a project containing a feature with front-matter status `review`.
2. Select Claude Code CLI as the AI backend.
3. Open that feature in the Feature panel and click `Implement with AI` without first creating issues.
4. Confirm that the prompt reaches the Terminal assistant and implementation begins.
5. Check the feature status in the Feature panel, file tree, and issue listing; check its lifecycle history immediately and again after more than 15 minutes.

## Expected

Once the prompt is successfully handed to the assistant, the feature's front-matter status becomes `implementing` and the UI reflects it. An `implementationStarted` lifecycle event is recorded reliably, even if the CLI session log cannot supply a model.

## Actual

After the Feature panel button sends the prompt and Claude Code CLI begins implementing, the feature remains at `review` in the reported UI locations. The user reports that no `implementationStarted` event appeared later.

## Environment

MarkView macOS app on Darwin 27.0.0; Feature panel button; Claude Code CLI backend.

## Suspected code

- `MarkView/Models/WorkspaceManager.swift` — `implementWithAI` sends the prompt but does not call `updateFeature` to set `implementing`. It records the event only when both a CLI tool and feature slug are available.
- `MarkView/Models/FeatureStore.swift` — `recordImplementationStarted` returns if there is no lifecycle project, then records from a detached task after `answeringModel` returns. That task may wait up to 15 minutes; it has no diagnostic reporting for failure or noncompletion.
- `MarkView/Views/FeaturePanelView.swift` — The reported button calls `implementWithAI(feature.folder)` directly; its action does not update feature status.
- `docs/architecture/modules/feature-workflow.md` — The status diagram documents entry to `implementing` through `createIssues`, but omits the user-required transition when `Implement with AI` hands off the feature.

## Likely causes

- Confirmed in code: `implementWithAI` sends the prompt and attempts to record a lifecycle event, but never updates the feature's front-matter status.
- Possible, unconfirmed: the feature slug was not resolved, the session had no CLI tool, lifecycle recording was unavailable, or the detached recording task did not complete. A missing Claude session log alone does not explain a permanently missing event: the code falls back to a configured model after polling ends.

## Missing information

- The cause of the missing lifecycle event is not established. A debug run should check slug resolution, the selected terminal session and tool, lifecycle project availability, and whether the detached task completes.
- The exact app version and feature path were not provided; they may help reproduce the lifecycle failure, but are not needed to begin fixing the confirmed status path.

## Clarifications

**BQ-1** Где вы нажали Implement with AI?
→ Панель фичи. Кнопка в Feature panel

**BQ-2** Появилось ли позже в истории фичи событие 'implementation started'?
→ Нет. Так и не появилось

**BQ-3** Какой статус должна получить фича после нажатия?
→ implementing. Отдельный статус implementing

**BQ-4** Какой ИИ-бэкенд был выбран, когда вы нажали Implement with AI?
→ Claude. Claude Code CLI

## Resolution (2.25.1)

- Root cause 1 (status): `WorkspaceManager.implementWithAI` sent the prompt but never changed the front matter.
  It now calls `FeatureStore.markImplementing`, the same rule as Create issues (`ready/resolving/review/draft/exploring`
  → `implementing`, shared as `Feature.beforeImplementation`).
- Root cause 2 (event): the event was written only after polling the CLI's session log for its first reply (up to
  15 minutes). It appeared late and was lost if MarkView quit first, e.g. for a reinstall. The log is append-only, so
  it is now recorded at the click. The model is what the running terminal has answered with, from one read of its
  session log; otherwise the model the terminal was started with or the configured default (owner's choice).
- Evidence: in `lifecycle-events.jsonl`, every Implement-with-AI prompt found in the Claude/Codex session logs has
  its event, but only after the reply. The 16:54Z press on `i-need-to-understand-a-real-answer-not` was still pending
  shortly before this report was filed.
- Verified in a test copy with its own bundle ID, on a fixture feature at `review`: 3 s after pressing the Feature
  panel's Implement with AI, `status: implementing` was in the file and the panel, and `implementation_started` was in
  the log.

## Original description

Вот фичу я нажал Implement with AI, он стал имплементировать, но почему-то статус пишет эту фичу Review, то есть Start Implementation он нигде не зафиксировал. По-моему это баг.
