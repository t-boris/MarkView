---
type: feature
id: agent-aware-implementation-runs
title: Agent-aware implementation runs
status: in-review
owner: Boris Tsekinovsky
created: 2026-11-24
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: partial
  Analytics: n/a
  Dependencies: partial
  Acceptance Criteria: known
schema: 1
understanding_notes:
  Problem: Из Build задача уходит в терминал. Связи с поэтапным исполнением и сбором доказательств Cockpit сейчас нет.
  Target Users: Пользователи MarkView, запускающие реализацию спецификации из Build.
  Primary Workflow: Пользователь может изменить рекомендацию Build. Cockpit выполняет утверждённый план последовательно и ведёт работу до применимой точки доставки. Формулировка причин рекомендации остаётся деталью реализации.
  Permissions: Утверждение плана уже обязательно. Для нового запуска каждый шаг Ask me требует отдельного явного согласия пользователя до действия.
  Failure Scenarios: Спецификация описывает недоступность режима, исчерпание лимита, неполные доказательства и сверку после прерванной доставки.
  Data Model: Нужна связь запуска со спецификацией, выбранным Definition of Done, подтверждениями и доказательствами по проверенной ревизии. Формат хранения определит реализация.
  Notifications: Причины паузы и запросы подтверждения относятся к интерфейсу запуска.
  Security: Текущий шлюз Cockpit ограничивает инструменты MarkView. Для команд в терминале охват зависит от профиля запуска. Проверка того, как профиль соблюдает ограничения и останавливает делегированную работу, нужна при реализации.
  Analytics: Требований к продуктовой аналитике нет.
  Dependencies: Cockpit и проверка доставки уже существуют. Возможности четырёх агентов зависят от установленных CLI и разрешений. Исследование не включало живые запуски.
  Acceptance Criteria: Критерии охватывают выбор запуска, порядок шагов, лимит, подтверждения и доказательства вплоть до применимой доставки. Дополнительных продуктовых решений не требуется.
questions_left: 0
issue: "#437"
---

# Agent-aware implementation runs

## Idea

Let MarkView turn a feature specification and its Definition of Done into a development run that uses the capabilities available in the selected agents and launch modes. The run can define goals and completion checks, schedule dependent work in order, delegate independent work where supported, and collect evidence from tests and code review.

## Problem

Implement with AI sends an implementation goal to a terminal. Cockpit can execute an approved multi-step plan, but the feature handoff does not connect to it or select execution capabilities for each step. Users must coordinate planning, delegation, verification, and review themselves when a single terminal handoff is insufficient.

## Scope

In scope for the draft are feature implementation from Build, specification-driven Cockpit plans, capability-aware execution for the four researched agents, run limits, and test and review evidence. Build recommends direct handoff or Cockpit based on the feature specification and the selected Definition of Done, shows the reason, and lets the user override the recommendation before launch. Cockpit execution requires separate plan approval. The managed run includes applicable delivery steps through merge and release, subject to project rules and the selected Definition of Done. It handles delivery approvals, tracks partial delivery, and retains evidence for existing lifecycle checks. Cockpit steps run sequentially, with delegation of independent work within a step when the selected agent's launch profile supports it and the approved controls allow it. General-purpose workflow authoring, changes to manually started terminal sessions, and new Cline integration are outside this draft. The draft treats “Implement VDI” as an example of a launch action and uses the existing Implement with AI entry point.

## Existing behaviour

- Implement with AI offers the Definition of Done for a project run, submits a goal to an assistant terminal, and records implementation as started only after a successful handoff. The current path does not open Cockpit. (`MarkView/Models/Workspace/FeatureFlowCoordinator.swift:334`)
- The handoff formats the goal for the receiving provider, includes the Definition of Done, and tells the assistant to apply recorded answers and accepted decisions as binding. (`MarkView/Models/Lifecycle/HandoffPrompt.swift:18`)
- The assistant registry includes Claude Code, Codex, GitHub Copilot, Antigravity, and Cline. The attached research covers the first four. (`MarkView/Models/AI/Providers/AssistantProviderList.swift:5`)
- Cockpit lists locally discoverable agent CLIs with the MarkView MCP service enabled and supplies their model choices to the planner. (`MarkView/Models/Cockpit/CockpitSession.swift:142`)
- Cockpit proposes a sequential plan with an agent, optional model, assignment, and verifiable completion condition per step. Users can edit agent and model assignments before approving. Prior approval and sequential execution are accepted decisions in docs/features/copilot-cockpit/decisions/DEC-001.md and DEC-010.md. (`MarkView/Models/Cockpit/CockpitPlanning.swift:15`)
- Temporal runs one Cockpit step at a time. Cockpit opens a separate project terminal for each agent attempt, and its current step policy refuses calls that start or drive other agents through MarkView. The policy gates MarkView tools. Direct shell and editor actions operate outside that gate. See MarkView/Models/Cockpit/CockpitAgentAttempt.swift and CockpitStepPolicy.swift. (`tools/cockpit-temporal/workflow.go:197`)
- Cockpit already tracks active step time, pauses the run when the configured time limit is reached, and records the interruption. CockpitPlan.swift distinguishes success, blocked, and unverified outcomes using criterion evidence. (`MarkView/Models/Cockpit/CockpitExecution.swift:245`)
- A pull request already has a Review action that opens PR X-Ray and starts an AI review. (`MarkView/Views/Git/GitHubViews.swift:360`)
- Definition of Done supports Require, Ask me, and Skip. The default asks before merge and skips versioning and delivery. CLAUDE.md requires a version bump, verified PR merge, and Release build with a signed DMG for changes to MarkView itself. IssueLifecycleEvidence.swift already evaluates merge, CI at the relevant commit, and required release evidence. (`MarkView/Models/Lifecycle/DefinitionOfDone.swift:127`)
