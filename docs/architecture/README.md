# MarkView Architecture Documentation

Reverse-engineered from the code at `main` `85b6f8d` (version 2.17.0, 2026-09-26). It is meant for
engineers and AI agents who need to change MarkView safely. Every module doc cites `path:line`;
when code and docs disagree, the code wins. Update the affected doc in the same change.

Project rules (build command, versioning, bridge-change rules) are in [`/CLAUDE.md`](../../CLAUDE.md).
Feature specs and bug reports produced *by* the app live in [`docs/features`](../features) and
[`docs/bugs`](../bugs).

## Reading order

| # | Doc | Read it to learn |
|---|---|---|
| 1 | [System overview](./system-overview.md) | What the app is, stack, container diagram, subsystem map |
| 2 | [Runtime flows](./runtime-flows.md) | Launch, open folder, edit/save, AI call, X-Ray, Insight, terminal link |
| 3 | [Data & storage](./data-and-storage.md) | Every file, database table group and cache the app writes |
| 4 | [Configuration](./configuration.md) | UserDefaults keys, localStorage, env vars, flags, entitlements |
| 5 | [External integrations](./external-integrations.md) | CLIs, HTTP endpoints, credentials |
| 6 | [Security model](./security.md) | Trust boundaries and known weaknesses |
| 7 | [Concurrency](./concurrency.md) | Threading model, process rules, known main-thread hazards |
| 8 | [Risks & tech debt](./risks-and-tech-debt.md) | Prioritised register of defects and debt found during the audit |
| 9 | [Operations runbook](./operations-runbook.md) | Build, run, debug a hang, logs, reset state, release |
| 10 | [Glossary](./glossary.md) | Project vocabulary |

## Module docs

| Module | Scope |
|---|---|
| [App shell & workspace](./modules/app-shell-and-workspace.md) | Entry point, windows, menus, `WorkspaceManager`, tabs, file tree, settings window |
| [Editor & bridge](./modules/editor-and-bridge.md) | WKWebView editor, `markview-*.js`, **bridge message catalog**, PDF export, vendored JS, `EditorWeb` status |
| [AI assistants & dictation](./modules/ai-assistants-and-dictation.md) | Claude/Codex/Cline/Copilot integration, prompts, Explain, code navigation, embeddings, Whisper |
| [Feature workflow](./modules/feature-workflow.md) | Feature/bug intake, AI rounds, on-disk spec schema (REQ/DEC/Q/F/SRC, BUG) |
| [Architecture & X-Ray](./modules/architecture-and-xray.md) | Repo scanner, component graph, AI grouping, Cytoscape map, PR X-Ray |
| [Semantic index & Insight](./modules/semantic-index-and-insight.md) | SQLite schema, structural indexer, GraphRAG prompt assembly, Recursive Insight |
| [Git, GitHub, terminal, lifecycle, usage](./modules/git-github-terminal-lifecycle-usage.md) | VCS panel, `gh` integration, PTY terminal and links, lifecycle analytics, quota tracker |
| [Build, release & testing](./modules/build-release-testing.md) | XcodeGen, settings, signing, release pipeline, standalone tests |

## Recipes index

Recipes for common changes are in each module's "Extension points" section:

- Add a bridge message → [editor-and-bridge §11](./modules/editor-and-bridge.md#11-extension-points-and-recipes)
- Add an AI provider/CLI → [ai-assistants-and-dictation](./modules/ai-assistants-and-dictation.md)
- Add a tab kind or a settings key → [app-shell-and-workspace §9](./modules/app-shell-and-workspace.md#9-extension-points-and-how-to-change-them-safely)
- Support a new language in the X-Ray scanner → [architecture-and-xray](./modules/architecture-and-xray.md)
- Add a feature object type → [feature-workflow](./modules/feature-workflow.md)
- Update a vendored JS library → [editor-and-bridge §11](./modules/editor-and-bridge.md#11-extension-points-and-recipes), [build-release-testing](./modules/build-release-testing.md)

## Maintenance

- These docs don't need a version bump (CLAUDE.md: docs-only changes).
- When a doc's `path:line` citations drift, refresh them rather than deleting them.
- The audit's defect findings are in [risks-and-tech-debt](./risks-and-tech-debt.md) and are **not fixed** by this doc set.
