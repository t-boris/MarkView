---
type: feature
id: project-operations-deploy-install-restart-buttons-from-x
title: "Project operations: Deploy / Install / Restart buttons from X-Ray Deployment"
status: implementing
owner: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the quick feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: known
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
intake: quick
issue: "#80"
understanding_notes:
  Problem: X-Ray только описывает развёртывание; команды приходится искать и запускать вручную.
  Target Users: Разработчик, работающий с проектом в MarkView на своей машине.
  Primary Workflow: Обнаружение операций, просмотр и правка, подтверждение, запуск как отдельного процесса с выводом и отменой.
  Permissions: Обнаружение читает вне корня проекта и ищет в сети без запроса (DEC-003); подтверждение перед каждым запуском (DEC-002).
  Failure Scenarios: "Состояния failed с кодом выхода и cancelled, запрет повторного запуска той же операции. Вывод ИИ: остальные крайние случаи разберёт ревью."
  Data Model: Список операций хранится в общем файле проекта, правки пользователя сохраняются при повторном обнаружении.
  Notifications: "Решено: индикаторы внутри приложения плюс уведомление macOS о любом завершении, когда MarkView не на переднем плане."
  Security: Секретами функция не управляет; ввод без эха передаётся процессу (DEC-007); показывается точная команда перед запуском.
  Analytics: Аналитика для этой функции не предусмотрена.
  Dependencies: Опирается на представление Deployment в X-Ray, сканер конфигурационных файлов и мост действий arch. Добавляется зависимость от разрешения на уведомления macOS.
  Acceptance Criteria: "Все решения владельца продукта приняты; критерии приёмки записаны в требованиях REQ-001–REQ-019."
questions_left: 0
---

# Project operations: Deploy / Install / Restart buttons from X-Ray Deployment

## Idea

Turn the project's operational CLI procedures into buttons. The user starts discovery from the project Deployment view. MarkView examines relevant project files and bounded external references, then uses the selected assistant to identify supported operations (deploy, install, build, clean, restart and others). Operations are stored in the project file and can be edited. A Deploy control appears in the project window and every project X-Ray view when deploy operations exist. The Deployment details panel lists all operations, including when no deployment map has been generated. Each run requires confirmation, then starts a separate interactive, cancellable process with a dedicated output panel.

## Problem

Today X-Ray only *describes* deployment: it draws a read-only map of services, apps, jobs and datastores. To actually deploy, install or restart, the user has to leave the map, remember or look up the correct CLI commands for each environment, and run them manually. The knowledge of how a project is deployed is partly already collected by MarkView (the deployment config files), but it is not actionable. For projects with non-trivial or unfamiliar install/deploy tooling, finding the right procedure is itself the costly part.

## Implementation contract

The approved requirements and accepted decisions in this folder are authoritative. In particular:

- Discovery starts only when the user chooses Discover or Re-discover (DEC-016). A changed source produces a staleness hint, not an automatic write (DEC-028).
- The project operations file is `.markview/operations.json` at the workspace root. It is shared with the team; user edits, additions, and tombstones survive re-discovery (DEC-004, DEC-005, DEC-017, DEC-027).
- Discovery reads project files, follows only bounded and safe references to external folders, then searches the web when supported (DEC-003, DEC-015, DEC-016). External and web commands remain individual proposals until accepted (DEC-026).
- Every run requires a native confirmation of the exact command and working directory. The native side resolves an id-only request from the operations file and runs the confirmed snapshot (DEC-002, DEC-013, DEC-014, DEC-022).
- Separate PTY subprocesses and output panels support interactive input. Different operations may run together; a single operation cannot run twice (DEC-001, DEC-007, DEC-008, DEC-019, DEC-020, DEC-021).
- Both the project window toolbar and every view of the project X-Ray have Deploy buttons. The picker lists deploy operations grouped by optional environment, including several targets in one environment. Folder X-Rays have no operations UI (DEC-006, DEC-018, DEC-027).
- The Deployment details panel lists all operations. For a selected node, related operations are highlighted first while all others remain available (DEC-009, DEC-027).
- In-app state and background notifications report completion. A remote trigger reports `dispatched` for exit code zero, without claiming the remote run succeeded (DEC-011, DEC-029, DEC-030).

The first version excludes editing deployment configuration, managing secrets, monitoring remote deployment after dispatch, scheduling or chaining operations, and rollback unless the project exposes a rollback command discovered as an operation (DEC-012). Detailed acceptance criteria live in requirements and the decisions that refine them.
