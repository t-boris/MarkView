---
type: feature
id: new-research-repository-grounded-analysis
title: "New Research: repository-grounded analysis"
status: implementing
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
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#28"
understanding_notes:
  Problem: Нет способа задать открытый аналитический вопрос по репозиторию и получить сохранённый документ.
  Target Users: Пользователи workspace, задающие аналитические/стратегические вопросы.
  Primary Workflow: New Research → вопрос + вложения → анализ → Markdown-отчёт открывается; кнопка «углубить/продолжить» дописывает тот же отчёт.
  Permissions: Локальный workspace, ролей нет.
  Failure Scenarios: "DEC-004: частичный документ с пометкой incomplete."
  Data Model: Один Markdown-документ на исследование, продолжения дописываются в него (DEC-002, подтверждено ответом C).
  Notifications: Не требуются.
  Security: Веб-поиск по усмотрению AI, источники цитируются (DEC-003).
  Analytics: Не требуется.
  Dependencies: AI-агент, веб-поиск, существующее New…-меню.
  Acceptance Criteria: Критерии заданы в REQ-001…REQ-004.
questions_left: 0
---

# New Research: repository-grounded analysis

## Idea

A fourth intake kind next to New Feature / New Bug / I Need to Understand: "New Research". The user poses an open analytical question (e.g. how to replace app A with app B, how to make the app more widely adopted, which features are missing, review of a document). The AI investigates using the current repository — code and/or documentation, possibly a docs-only repository — optionally plus external knowledge, and produces a persistent Markdown research result.

## Problem

Existing intake kinds cover building (feature), fixing (bug) and locating/explaining things in the project (understand → X-Ray ⚡ search, no document). There is no way to ask an open-ended analytical or strategic question grounded in the repository and get a saved, structured research document as the result.

## Scope

IN: new intake kind "Research" in the New… menu; free-text question plus attachments; analysis over the repository's code and documents (works for docs-only repositories); output saved as a Markdown research document with findings, recommendations and cited sources (project files vs external facts vs AI inferences kept apart); opening the result after creation. OUT (for now): automatic conversion of recommendations into features/issues; scheduled/recurring research; editing the analysed documents in place.
