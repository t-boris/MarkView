---
type: feature
id: project-operations-deploy-install-restart-buttons-from-x
title: "Project operations: Deploy / Install / Restart buttons from X-Ray Deployment"
status: ready
owner: Boris Tsekinovsky
created: 2026-09-29
provenance: Created from the quick feature intake
understanding:
  Problem: known
  Target Users: partial
  Primary Workflow: partial
  Permissions: known
  Failure Scenarios: partial
  Data Model: known
  Notifications: partial
  Security: known
  Analytics: n/a
  Dependencies: partial
  Acceptance Criteria: partial
intake: quick
issue: "#80"
understanding_notes:
  Problem: "Проблема описана в обзоре: X-Ray только показывает развёртывание, команды приходится искать и запускать вручную."
  Target Users: "Вывод ИИ: пользователь — разработчик, который сам развёртывает проект со своей машины. Список операций общий для команды (DEC-005). Явно пользователем не подтверждено, но на требования почти не влияет."
  Primary Workflow: "Решены способ запуска, подтверждение, панель вывода с вводом, правка списка, расположение кнопки Deploy. Не решено: можно ли запускать несколько операций одновременно; какие виды операций входят в первую версию (открытое решение 7)."
  Permissions: Обнаружение читает вне проекта и ищет в сети без запроса (DEC-003); перед каждым запуском — подтверждение (DEC-002).
  Failure Scenarios: "Решены: ошибка запуска, ненулевой код выхода, отмена, запрос ввода (DEC-007). Не решено поведение при попытке запустить операцию, пока другая ещё выполняется."
  Data Model: Список операций хранится в общем файле проекта, правки пользователя сохраняются при повторном обнаружении (DEC-004, DEC-005).
  Notifications: Состояние видно в панели и на обеих кнопках. Не решено, нужно ли уведомление о завершении длительной операции, когда панель не на экране.
  Security: Секретами система не управляет; подтверждение перед каждым запуском; ввод без эха не показывается и не сохраняется в выводе.
  Analytics: Аналитика для этой функции не требуется.
  Dependencies: "Факт проекта: есть карта развёртывания X-Ray и встроенный PTY-терминал. Вывод ИИ: для запросов ввода подпроцессу нужен псевдотерминал; это деталь реализации. Расширение списка распознаваемых файлов (package.json, скрипты, Justfile) пока не зафиксировано требованием."
  Acceptance Criteria: Критерии есть для запуска, панели, подтверждения, обнаружения, правки и кнопки Deploy. Нет критериев для одновременных запусков и для списка операций в панели деталей X-Ray.
questions_left: 3
---

# Project operations: Deploy / Install / Restart buttons from X-Ray Deployment

## Idea

Turn the project's operational CLI procedures into buttons. When X-Ray maps a project's deployment, MarkView also discovers the operations the project actually supports (deploy per environment, install, build, clean, restart, etc.) and the exact commands behind them. A "Deploy" button with an environment picker appears for projects that have a deployment, and selecting the Deployment view (or a deployment node) shows the available operation buttons in the right-hand details panel. Running an operation starts a long-running, observable, cancellable process instead of requiring the user to type commands in a terminal. When the procedure uses tooling the AI does not recognise, or lives in another local folder/project, the discovery step investigates (local folders, then the web) before proposing a command.

## Problem

Today X-Ray only *describes* deployment: it draws a read-only map of services, apps, jobs and datastores. To actually deploy, install or restart, the user has to leave the map, remember or look up the correct CLI commands for each environment, and run them manually. The knowledge of how a project is deployed is partly already collected by MarkView (the deployment config files), but it is not actionable. For projects with non-trivial or unfamiliar install/deploy tooling, finding the right procedure is itself the costly part.

## Scope

IN SCOPE
- Discovery of operations: an AI pass that produces a list of operations (id, label, kind: deploy | install | build | clean | restart | other, environment if any, command, working directory, source file/line the command was derived from, confidence, prerequisites).
- Discovery of environments (e.g. dev / staging / prod) from the project's own files; one deploy operation per environment found.
- UI: a "Deploy" button with an environment picker, shown only when at least one deploy operation was found; an operations list in the X-Ray details panel for the Deployment view / selected deployment node.
- Execution of a chosen operation as a long-running process with live output, visible state (running / succeeded / failed with exit code) and cancel.
- Investigation fallback when tooling is unknown: search local folders, then the web; report what was found and how confident the result is.
- User review of the discovered command before its first run.

OUT OF SCOPE (proposed, not yet decided)
- Authoring or changing deployment configuration.
- Managing secrets or credentials; operations use whatever the user's shell environment already provides.
- Remote monitoring of the deployed system after the command exits.
- Scheduling or chaining operations into pipelines.
- Rollback, unless the project itself exposes a rollback command that discovery finds.

OPEN DECISIONS (not decided by the user; need discussion)
1. Execution mechanism: (a) paste the command into an embedded terminal tab, (b) run a dedicated subprocess with its own output panel, (c) hand the task to the AI agent terminal. Inference: (a) reuses existing PTY infrastructure and handles interactive prompts; (c) is the least predictable for production deploys.
2. Placement of the "Deploy" button: X-Ray toolbar, details panel, project/window toolbar, or several of these. The request says "somewhere".
3. Whether discovery may read outside the project root (the request mentions install living in "another project") and how that folder is chosen or approved.
4. Whether web research is allowed automatically or only on user confirmation.
5. Safeguards for production-like environments (explicit confirmation, typed environment name, etc.).
6. Where discovered operations are stored and whether the user can edit them (e.g. a project file under docs/ or .dde/ vs. database only).
7. Which operation kinds belong to the first version. "Clean", "refresh" and "restart" were given as examples, not as a fixed list.

## Analysis

PROJECT FACTS (verified in code and docs)
- The X-Ray Deployment view exists and is AI-mapped from build/deploy config files (docs/architecture/modules/architecture-and-xray.md §1, §5.2 step 3; ArchitectureStore.mapDeployment, MarkView/Models/ArchitectureStore.swift:522-613).
- The deployment schema contains only nodes (id, name, kind, tech, summary, parent, runs) and edges (source, target, label). It has no concept of environment, command or operation. Node kinds: service, app, job, datastore, queue, client, infra, external.
- The mapping prompt explicitly forbids reading anything: config files are inlined (max 4,000 chars each, 40,000 total) and the assistant is told to work only from them. It cannot currently investigate unknown tooling.
- Config files are detected by ArchitectureScanner.isDeploymentHint (ArchitectureScanner.swift:254-268): Dockerfile/Containerfile, compose files, Procfile, fly.toml, vercel.json, netlify.toml, serverless.yml, app.yaml, render.yaml, railway.json, skaffold.yaml, Chart.yaml, project.yml, Info.plist, cloudbuild.yaml, buildspec.yml, nginx.conf, Makefile, *.tf, *.entitlements, *.xcconfig, .github/workflows/*, and yml/yaml/json under k8s, kubernetes, helm, charts, deploy, deployment, infra, terraform folders.
- Not detected today: package.json scripts, shell scripts (deploy.sh, install.sh), Justfile, Taskfile, Fastlane, README/runbook instructions. These are common places where deploy/install commands live.
- The Deployment view is remapped only when the config-file signature changes; results are persisted in the arch_* tables of .dde/state.db and answers are cached by request hash.
- The details panel is rendered by renderDetails in markview-architecture.js. New actions follow a documented recipe: post an `arch` bridge action from JS, add a case in WorkspaceManager.handleArchitectureAction with payload validation, implement on ArchitectureStore (§9 "Add a bridge action").
- Existing process infrastructure: an embedded PTY terminal (TerminalSession) with live output, restart and exit-code reporting; folder terminal tabs (WorkspaceManager.openTerminal(in:)); pasteWhenReady(_, submit:) for delivering text to a terminal; GitHubClient.execute for non-interactive subprocesses with a default 60 s timeout.
- GitHub Actions workflow dispatch already exists (gh workflow run with parsed inputs), behind the opt-in GitHub setting. Projects that deploy through a workflow_dispatch workflow already have a partial path.
- Existing menu item "Deployment" (ContentView.swift:899) only opens the Mermaid graph creator; it is unrelated to running a deployment.
- Read-only AI agents with Read/Grep/Glob restricted to one folder exist (readableFolder, used by ⚡ search, up to 900 s). No existing X-Ray call has web access or access outside the root.
- Documented security stance (docs/architecture/security.md): subprocess arguments as arrays, never shell-interpolate repo strings; keep AI calls read-only unless the user explicitly starts an agent terminal. Known risks already recorded: AI terminals run with full permissions (S4); config content is sent to AI CLIs without redaction (S14); a large terminal write can be truncated silently (terminal risk B.10.2).

AI INFERENCES (not facts)
- Operations should be a separate artifact from the Deployment view's nodes: a command is per project/environment, not necessarily per node, and its cache/refresh lifecycle differs from the map.
- Discovery needs a different AI pass than mapDeployment: it needs file-reading tools and a wider input set, so it will be slower and should run on demand or in the background, not block the map.
- Commands derived by AI from repository content are an injection surface: a malicious or mistaken repo file could produce a destructive command. Showing the command and its source before the first run, and re-confirming when the command changes, is the minimum mitigation. This conflicts with a pure "one click" experience and needs a user decision.
- The 60 s default timeout of the existing non-interactive runner is unsuitable for deploys; long operations need no timeout or a user-visible one.
- Deploys often prompt interactively (passwords, confirmations, 2FA), which favours a PTY over a plain subprocess.

OPEN ASSUMPTIONS
- "Environment" means a named deploy target found in the project's files; it is unknown how projects with no explicit environment names should be presented (single unnamed "Deploy"?).
- It is assumed that operations run on the user's machine with the user's existing credentials.
- It is unknown whether the feature must work for folder X-Rays or only for the project X-Ray.
- Behaviour when discovery finds nothing is assumed to be "no buttons shown, with an explanation", not an error.

## Acceptance Criteria

- [ ] After X-Ray analysis of a project that has deploy configuration, a list of discovered operations is available, each with a label, kind, command, working directory, optional environment, and the file (and line where possible) the command was derived from.
- [ ] When at least one deploy operation exists, a Deploy button is visible; activating it lets the user choose among exactly the environments that were discovered. With a single target, no picker step is required.
- [ ] When no deploy operation is discovered, no Deploy button is shown and the Deployment view explains that no runnable deployment procedure was found.
- [ ] With the Deployment view active, the details panel lists all discovered operations (e.g. install, build, clean, restart) as buttons; selecting a deployment node narrows the list to operations relevant to that node when such a relation is known.
- [ ] Before an operation runs for the first time, the user sees the exact command, its working directory and its source, and must confirm. If the discovered command later changes, confirmation is required again.
- [ ] Operations targeting an environment identified as production require an explicit additional confirmation on every run.
- [ ] A started operation shows live output and a running state; the UI remains responsive, and the user can keep working in other tabs while it runs.
- [ ] A running operation can be cancelled by the user; the final state shows succeeded or failed together with the exit code, and the output stays readable after completion.
- [ ] An operation that needs interactive input (password, confirmation prompt) can receive that input from the user.
- [ ] Operations running longer than 60 seconds are not terminated by a default timeout.
- [ ] When the procedure relies on tooling the AI cannot identify from the project files, discovery investigates further and the resulting operation states where the information came from (local path or URL) and a confidence level; low-confidence operations are visibly marked and never run without review.
- [ ] Discovery never executes project commands or modifies files; it is read-only.
- [ ] Any read outside the project root and any web lookup happens only in the way the user has approved (exact policy is an open decision).
- [ ] Commands are never assembled by interpolating unvalidated repository strings into a shell line by the app itself; the command shown to the user is exactly the command that runs.
- [ ] Discovered operations persist across app restarts and are refreshed when the relevant source files change; a manual re-discover action is available.
- [ ] Two operations for the same project cannot be started concurrently by accident: starting a second one while one is running requires an explicit choice.
