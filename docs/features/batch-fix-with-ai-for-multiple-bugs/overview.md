---
type: feature
id: batch-fix-with-ai-for-multiple-bugs
title: Batch "Fix with AI" for multiple bugs
status: implemented
owner: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the feature intake
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
issue: "#31"
understanding_notes:
  Problem: Исправлять связанные баги по одному дорого, а у исправлений нет своей ветки.
  Target Users: Пользователь рабочего пространства, который исправляет баги с помощью AI.
  Primary Workflow: Пользователь собирает баги в корзину, запускает один Fix with AI, AI создаёт ветку и делает по коммиту на каждый баг.
  Permissions: Не применимо.
  Failure Scenarios: При грязном рабочем дереве или уже существующей ветке AI спрашивает пользователя; частичный успех отражается в статусе каждого бага.
  Data Model: Корзина багов и статус каждого бага; как их хранить, решает разработчик.
  Notifications: Не применимо.
  Security: Не применимо.
  Analytics: Не применимо.
  Dependencies: Используются существующий AI-терминал и fixBugWithAI; ветку создаёт AI.
  Acceptance Criteria: Критерии приёмки записаны в REQ-001–REQ-006.
questions_left: 0
---

# Batch "Fix with AI" for multiple bugs

## Idea

Let the user select several bug reports in a feature's Bug panel and start one "Fix with AI" run for all of them. The AI works on a single git branch and fixes the selected bugs together.

## Problem

Today "Fix with AI" (`WorkspaceManager.fixBugWithAI`, FeaturePanelView.swift:622) takes one bug at a time. It sets that bug's status to `fixing` and sends a single-bug prompt to the AI terminal. It does not create a branch. Fixing related bugs one by one costs extra runs, and the fixes end up scattered or mixed in the working tree without a dedicated branch.

## Scope

IN: an 'Add to basket' / 'Remove from basket' control on open bugs in the Issues panel; one basket per window, in memory, kept while features are opened and closed and emptied for another folder; bugs from any feature, identified by path (DEC-015); the basket view (count, items with their feature when known, remove, clear, 'being fixed' marking, a notice for closed or deleted bugs); 'Suggest similar' as a read-only structured AI call (DEC-014); one 'Fix with AI' for 2+ open bugs, disabled while the AI terminal is busy (DEC-016); one prompt that has the AI create one branch (asking first on other uncommitted changes or an existing branch), fix each bug with its own commit, and write each outcome into the report (fixed + branch, or open + 'AI fix attempt' note). Every bug becomes 'fixing' at start and the basket is emptied. The single-bug Fix with AI is unchanged.

OUT: automatic PR creation; running batches in parallel; a persistent batch record (DEC-013).

## Implementation

`Models/BugBasket.swift` (rules and prompts, tested by `tools/tests/bug-basket-tests.sh`), `Models/BugBatch.swift` (the window's basket), `Views/BugBasketView.swift` and the basket toggle in `Views/FeatureNavigatorView.swift`, `WorkspaceManager.fixBasketWithAI()` and `assistantIsBusy`. Version 2.21.0.
