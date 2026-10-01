---
type: bug
id: BUG-016
title: Add bug discussion and a Quick Feature intake path
status: fixed
branch: fix/issue-workflows
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где именно вы ожидаете поле свободного обсуждения бага?
    why: Это определит точку входа и поможет воспроизвести отсутствие функции.
    options:
      - label: При создании
        text: Сразу после создания бага.
      - label: В панели бага
        text: При открытии существующего бага в панели Feature.
      - label: В обоих местах
        text: И после создания, и при повторном открытии.
    status: answered
    answer: В обоих местах. И после создания, и при повторном открытии.
  - id: BQ-2
    text: Как обсуждение должно менять состояние бага перед разработкой?
    why: Сейчас доступны статусы open, fixing, fixed и closed; правило перехода из описания неясно.
    options:
      - label: Сразу готов к разработке
        text: После обсуждения пользователь вручную передаёт баг в разработку.
      - label: AI предлагает готовность
        text: AI оценивает готовность, а пользователь подтверждает передачу.
      - label: Автоматический переход
        text: AI сам меняет статус, когда данных достаточно.
    status: answered
    answer: AI предлагает готовность. AI оценивает готовность, а пользователь подтверждает передачу.
issue: "#70"
---

# Add bug discussion and a Quick Feature intake path

## Summary

Requested bug discussion and Quick Feature intake capabilities are absent. The clarifications establish that bug discussion is needed both immediately after creation and on reopening, and that AI should propose readiness while the user confirms handoff. This is a feature gap rather than an observed regression.

## Steps to reproduce

1. Open a workspace and create a New Bug from the Issues navigator.
2. Immediately after creation, open its bug panel and try to send a free-form request to recheck or revise the analysis.
3. Close and reopen the bug before selecting Fix with AI; try the same follow-up.
4. Start New Feature and look for a Quick Feature choice that avoids the full question workflow.

## Expected

After creation and on reopening before development, a bug offers free-form AI discussion. The AI can recheck its analysis and revise the report from that discussion. The AI proposes when the bug is ready for development, and the user confirms the handoff. New Feature offers a Quick Feature choice that creates a concise, single-page specification with analysis and discussion, without the full question workflow.

## Actual

The bug panel offers question cards, Investigate, manual status selection, and Fix with AI, but no free-form bug discussion. New Feature calls the full feature intake path; Quick Feature is absent.

## Environment

MarkView native macOS app (SwiftUI), targeting macOS 13+. Affected surfaces: Issues navigator intake sheet and bug Feature panel. Reporter build and macOS version are unknown; code inspection is sufficient to locate these missing capabilities.

## Suspected code

- `MarkView/Views/FeaturePanelView.swift` — BugPanelView renders structured questions, Investigate, manual status selection, and Fix with AI, but no free-form bug discussion control.
- `MarkView/Models/FeatureIntake.swift` — answerBug requires a question ID; investigateBug performs a report rewrite; IntakeKind and newFeature expose only the full feature intake route.
- `MarkView/Models/FeatureStore.swift` — Discussion append and retrieval target a feature's discussion.md; no bug discussion equivalent is evident.
- `MarkView/Models/FeatureModels.swift` — BugReport stores status, but the model has no rule for AI readiness proposals or user-confirmed handoff.
- `MarkView/Views/FeatureNavigatorView.swift` — The intake sheet dispatches the feature choice directly to newFeature without a Quick Feature option.
- `docs/architecture/modules/feature-workflow.md` — The documented bug path uses question rounds and re-investigation; free-form discussion is documented for features, and New Feature has one intake flow.

## Likely causes

- Bug answers are tied to question IDs; Investigate is a one-shot report rewrite without a conversational message path.
- Discussion storage and UI are implemented for features, with no corresponding bug discussion path evident.
- The intake kind and sheet provide one feature route, which calls newFeature.
- The current bug status behavior has no AI readiness proposal followed by user confirmation.

## Missing information

- The Quick Feature document shape and its relationship to the existing feature lifecycle remain product decisions for implementation, but are not needed to reproduce or locate the missing path.
- The exact reporter build and macOS version were not supplied; they are not needed to locate these code-level omissions.

## Clarifications

**BQ-1** Где именно вы ожидаете поле свободного обсуждения бага?
→ В обоих местах. И после создания, и при повторном открытии.

**BQ-2** Как обсуждение должно менять состояние бага перед разработкой?
→ AI предлагает готовность. AI оценивает готовность, а пользователь подтверждает передачу.

## Original description

Когда мы создаём баг, у нас нет возможности дискашена, то есть нет возможности сказать что-то модели, чтобы она перепроверила это всё. Это неудобно. Ну, короче, я считаю, что нужно сделать две вещи в багах. Создать возможность дискашена, чтобы он менял состояние бага в зависимости от нашего дискашена, перед тем, как отдаём яйл на разработку. И второе, когда мы делаем фичи, я хочу сделать, чтобы был выбор quick, так сказать, quick, быстрая фича, в которой мы не проходим все вот эти вопросы бесконечные. А что-то очень простое добавить, так сказать, одностраничное, очень похоже на баг, где он просто анализирует это, есть возможность дискашен и всё такое, но это фича.
