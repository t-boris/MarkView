---
type: feature
id: task-aware-agent-execution
title: Task-Aware Agent Execution
status: done
owner: Boris Tsekinovsky
created: 2026-11-25
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
  Analytics: known
  Dependencies: known
  Acceptance Criteria: known
schema: 1
understanding_notes:
  Problem: MarkView использует разные профили запуска. В Fix with AI промпт может формироваться до выбора терминала, а исходный аудит не содержит сравнительных замеров.
  Target Users: Пользователи MarkView, которые запускают агентные сценарии из приложения.
  Primary Workflow: Аудит охватывает все запуски из MarkView. Подтверждённые улучшения выходят вместе, а каждое новое исследование в первом релизе по умолчанию использует глубокий режим.
  Permissions: Замена явно выбранного провайдера требует подтверждения. Для доступа к источникам действуют настройки репозитория и возможности фактического профиля запуска.
  Failure Scenarios: Research сохраняет пригодные материалы при прерывании. Если глубокий режим медленнее или дороже и существенный прирост качества не подтверждён, выпуск ждёт доработки и успешного повторного сравнения.
  Data Model: Для аудита определён состав сведений о вызове. Формат хранения остаётся решением реализации.
  Notifications: Отдельный сценарий уведомлений не требуется.
  Security: Контекст передаётся предложенному провайдеру только после подтверждения. Действуют существующие ограничения на делегирование, запись и выпуск.
  Analytics: Сравнение учитывает качество, длительность и доступные данные о затратах. Журнал фоновых вызовов фиксирует исход выполнения до проверки результата.
  Dependencies: Доступность возможностей зависит от установленного провайдера и фактического профиля запуска. Аудит проверит эти возможности в затронутых сценариях.
  Acceptance Criteria: Q-005 определил условие выпуска для Research. Критерии существенного прироста задаются для каждого сценария до сравнения. Результаты замеров предстоит получить при реализации.
questions_left: 0
issue: "#444"
---

# Task-Aware Agent Execution

## Idea

Audit every agent invocation initiated by MarkView and adapt its prompt and execution strategy to the task and the actual launch profile. Use existing agent capabilities where they improve the outcome, including direct execution for straightforward work, parallel work for independent tasks, deeper research for broad questions, and additional review where warranted.

## Problem

Agent workflows have different needs, and their current launch paths use available capabilities unevenly. Fix with AI can prepare a prompt for a different provider than the receiving terminal. Research map generation uses a single background operation, while Insight already supports bounded parallel work. The attached static review identifies opportunities, but provides no live comparison showing which changes improve results, latency, or cost.

## Scope

In scope are the inventory and optimization of MarkView-initiated prompts and launches across registered assistants, including background CLI and ACP, terminal handoffs that MarkView submits to the agent for execution, Cockpit, inter-agent actions, and Remote Work. The audit covers each path, and the first release includes every improvement confirmed by the full audit and verification. Out of scope are prompts typed manually in terminals, adding new assistant providers, redesigning Cockpit approval or delivery, and using capability coverage percentages as a success measure.

## Existing behaviour

- The attached research map is marked incomplete. It identifies candidate workflows and launch-profile gaps, and records that quality, cost, and latency were not measured in live runs. (`docs/research/2026-11-25-proanaliziruem-vezde-li-my-v-marku-ispol-zuem.md`)
- MarkView registers Claude Code, Codex, Cline, GitHub Copilot, and Antigravity. Background and interactive launches have distinct capabilities. For example, the background Claude profile omits delegation tools (ClaudeProvider.swift:172), while the interactive Cockpit profile declares a delegation mechanism (ClaudeProvider.swift:13). (`MarkView/Models/AI/Providers/AssistantProviderList.swift:5`)
- Background operations use AIOperation and run through either a one-shot CLI or ACP. AIOperation also supports response validation and bounded repair attempts (MarkView/Models/AI/AIOperation.swift:270). (`MarkView/Models/AI/CLICompletion.swift:221`)
- Interactive handoffs prefer an explicitly supplied terminal, then the visible assistant, then an open terminal for the configured provider, then any open assistant terminal. A new terminal opens if none matches those rules. (`MarkView/Models/Workspace/AITerminalsController.swift:395`)
- Single and batch Fix with AI send terminal prompts and mark bugs as fixing after a successful handoff. The single-bug flow builds its provider-specific prompt before terminal selection, so the configured provider and actual recipient can differ. The feature implementation handoff builds its prompt after selecting the recipient (line 369). (`MarkView/Models/Workspace/FeatureFlowCoordinator.swift:403`)
- Build already supports direct handoff and managed Cockpit runs (MarkView/Models/Workspace/WorkspaceManager.swift:111). Managed runs require plan approval, keep Cockpit steps sequential, and allow supported delegation within approved steps. Independent review and delivery gates are already specified in REQ-004. (`docs/features/agent-aware-implementation-runs/requirements/REQ-002.md`)
- A map run streams updates from one background operation and can save a partial map. The Deep Research menu opens the same New Research intake (docs/features/new-research-repository-grounded-analysis/decisions/DEC-010.md). The current evidence check verifies the presence of a repository path or URL, leaving claim-level support unverified (MarkView/Models/Research/ResearchDocument.swift:151). (`MarkView/Models/Research/ResearchMapJobs.swift:246`)
- Research checks the repository web setting and whether the backend uses ACP. Project Operations also checks the provider's declared web capability before its second round (MarkView/Models/ProjectOps/ProjectOperationDiscoveryService.swift:77). Research permission alone therefore does not establish web availability for a run. (`MarkView/Models/Research/ResearchJobs.swift:205`)
- Insight already runs independent sections with bounded concurrency and supports retrying an individual section. Codebase Audit generates planned documents and optional diagrams sequentially (MarkView/Models/Workspace/WorkspaceManager+AIToolRuns.swift:229). (`MarkView/Models/Insight/InsightSession.swift:985`)
- The background call log records provider, model, effort, duration, token usage, available cost, and execution outcome without storing prompt or answer text. Execution success is recorded before AIOperation validates the result. (`MarkView/Models/AI/AICallLog.swift:6`)
