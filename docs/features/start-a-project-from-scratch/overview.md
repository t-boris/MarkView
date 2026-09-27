---
type: feature
id: start-a-project-from-scratch
title: Start a Project from Scratch
status: implemented
owner: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#38"
understanding_notes:
  Problem: Известен разрыв между работой с существующей папкой и запуском проекта с нуля.
  Target Users: Пользователь начинает без файлов и репозитория, возможно лишь с общей идеей.
  Primary Workflow: Выбраны адаптивное уточнение, подтверждение замысла, создание локального проекта и необязательное подключение GitHub.
  Permissions: Создание предлагается после подтверждения замысла; подключение GitHub выбирает пользователь.
  Failure Scenarios: Дополнительного продуктового выбора нет; конкретные ошибки создания и подключения проверяются при реализации.
  Data Model: В проекте сохраняются подтверждённое описание, решения и требования. Форматы файлов определит реализация.
  Notifications: Уведомления не входят в сценарий.
  Security: Подключение GitHub необязательно; иных продуктовых решений в заявленном объёме нет.
  Analytics: Аналитика не входит в сценарий.
  Dependencies: Подключение опирается на существующую интеграцию GitHub; технические детали определит реализация.
  Acceptance Criteria: Результат создания проекта и необязательное подключение GitHub можно проверить по обновлённым критериям.
questions_left: 0
---

# Start a Project from Scratch

## Idea

A user can start a new project in MarkView with no existing files or repository, explain what they want to build, and be guided through creating the project foundation and connecting it to GitHub.

## Problem

MarkView currently centers its workflow on opening an existing folder. Its documented feature intake helps turn an idea into a specification, while GitHub integration works with a repository detected from a Git remote. There is no documented end-to-end path from an empty starting point to a bootstrapped, GitHub-connected project.

## Scope

In: a new-project entry point for an empty starting state, clarification of the project idea, a bootstrap outcome, and a path to GitHub connection. Out for this initial specification: prescribed technology stack, generated file templates, repository visibility, deployment, and automated implementation; these need decisions before they can be specified.
