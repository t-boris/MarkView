# Data and Storage

This page lists everything MarkView persists, grouped by location. Schemas are in the owning
module doc. Checked against `ac3001ba` (6.26.2 plus the architecture-review finish, 2026-11-15).

The table lists the main locations; where a file lives inside a project is named once, in `ProjectPaths` (`Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift`,
`AR-24`); lint rule `project-paths` forbids a `".dde` or `".markview-` literal anywhere else. A JSON store that carries a schema
version is read and written through `SchemaVersionedStore` (`AR-36`): a missing, damaged or newer-schema file is reported and never
overwritten as if it were empty.

## 1. Inside the workspace (per project)

| Path | Format | Owner | Notes |
|---|---|---|---|
| `.dde/state.db` (+ `-wal`, `-shm`) | SQLite 3, WAL, FTS5, `PRAGMA user_version` = number of the last migration (4 in this build) | `SemanticDatabase` (actor), schema in `SemanticSchema.migrations` | Documents, symbols, relations, FTS, token usage, `arch_*` X-Ray tables. Nonempty legacy tables may remain (see [semantic §10](./modules/semantic-index-and-insight.md)). Schema: [semantic §6](./modules/semantic-index-and-insight.md), [X-Ray §6.1](./modules/architecture-and-xray.md#61-project-x-ray-sqlite-ddestatedb) |
| `.dde/file_<name>.db` | SQLite | `SemanticDatabase` | Single-file workspace, in the file's parent folder |
| `.dde/cache/{provider_responses,embeddings,indexes}`, `.dde/overlays` | directories | `ProjectContext` (`openDatabase`) | Created on open, but nothing writes to them |
| `.dde/cache/xray/<sha>.json` | JSON | `ArchitectureStore` (`ProjectPaths.xrayCacheFolder`) | AI answer cache |
| `.dde/cache/xray/terms-<sha24>.json` | JSON | `FilterSearch` | AI filter search terms |
| `.dde/cache/xray-content/<sha(abs path)>.json` | JSON | `XRayContent` | File outlines. Folder X-Rays write these inside the scanned folder |
| `.dde/cache/explain/<sha256(path)[:24]>.json` | JSON | `CodeExplainStore` (folder from `CodeAndXRayCoordinator`) | Explain margin notes |
| `.dde/xray-folders/<sha24>.json` | JSON | `CodeAndXRayCoordinator` / `ArchitectureStore` | Folder X-Ray snapshots |
| `.dde/understanding/` | files | `XRayFilterStore` | Saved search-understanding answers |
| `.dde/workflow/workflow.json` | JSON | `ProjectWorkflowStore` | The project's workflow definition |
| `.dde/lifecycle/{cycle-time.json,transitions.jsonl,sessions.jsonl}` | JSON / JSON Lines | `CycleTimeReport`, `IssueTransitionLog`, `IssueLifecycleContext` | Cycle-time settings, issue transitions, agent sessions per issue |
| `.dde/qa/` | files | `QAStore` | QA runs, baselines, findings |
| `.dde/studio/` (`attachments/`, `captures/<id>.png`, `titanium-data/`) | files | `UIStudioStore`, `UIStudioAgents`, `WebAppPreview` | UI Studio sessions and their pictures |
| `.dde/cockpit/{runs,results,temporal}/` | JSON | `CockpitRunStore`, `CockpitResults`, `CockpitRuntime` | Cockpit plans and runs, their results, temporal state |
| `.dde/discussions/` | JSON | `Discussion` | Discussion threads |
| `.dde/prototypes/` (legacy), `.dde/exports/prototypes/` | files | `PrototypeFiles` | Prototypes made before DEC-006 move to `docs/prototypes` once, when the folder opens; exports stay under `.dde/exports` |
| `.dde/github-connection.json` | JSON | `NewProject` (`GitHubConnectionRecord`, `Models/Git/GitHubConnection.swift`) | Target, visibility, created/committed/pushed; deleted once connected |
| `.markview-insight/` (`nodes/<UUID>.html`, `manifest.json`, `snapshot.json`, `_assets/**`) | HTML/JSON + copied vendor JS | `InsightCache` | Kept after the tab closes. The root id is the SHA-256 of the folder path, so moving the folder orphans it |
| `docs/features/<slug>/` | Markdown + YAML front matter | `FeatureStore` | `overview.md`, `discussion.md`, `requirements/REQ-nnn.md`, `questions/Q-nnn.md`, `decisions/DEC-nnn.md`, `findings/F-nnn.md`, `research/R-nnn.md`, `references/SRC-nnn*.md`, `implementation/plan.md`, `diagrams/*.md`. Schema: [feature-workflow §6](./modules/feature-workflow.md#62-front-matter-fields) |
| `docs/bugs/BUG-nnn-<slug>.md`, `docs/bugs/assets/` | Markdown + YAML | `FeatureStore` | Bug reports with `BQ-n` questions |
| `docs/research/RES-nnn-<slug>.md` | Markdown + YAML | `XRayFilterStore` | Saved search answers |
| `docs/prototypes/` | files | `PrototypeFiles` | Prototypes |
| `.claude/CLAUDE.md` | Markdown | generated context | Deleted by Remove Metadata only if it starts with the generated header (`ProjectContext.metadataItems`) |
| `.gitignore` | text | `GitClient.ignore` | Appended by the Git view's "Add to .gitignore" action |

All of `.dde/` and `.markview-insight/` can be regenerated. Deleting them
(**File ▸ Remove Metadata…**) loses X-Ray AI groupings and descriptions, Explain notes and Insight
documents, but no user content.

## 2. Per user (`~`)

| Path | Format | Owner |
|---|---|---|
| `~/Library/Application Support/MarkView/recentFiles.json` | JSON array of paths (≤20), a `SchemaVersionedStore`. Loaded and saved by `ProjectContext`; no view or menu reads `recentFiles` (`git grep recentFiles` outside `ProjectContext` finds none in the app target) | `ProjectContext` |
| `~/Library/Application Support/MarkView/windowSessions.json` | JSON: every window's frame, folder, tabs, panels, theme and interface state. A build with another bundle id uses `MarkView-<bundle id>/` | `WindowSessionController` (`WindowSessionStorage`) |
| `~/Library/Application Support/MarkView/ai-calls.jsonl` | JSON Lines, one line per CLI completion: label, tool, model, effort, seconds, tokens, cost, outcome. No prompt or answer text | `AICallLog` |
| `~/Library/Application Support/MarkView/{themes,layouts,WorkflowTemplates}/` | files a person adds: theme definitions, layout presets, workflow templates (read next to the bundled ones) | `ThemeCatalog`, `LayoutCatalog`, `WorkflowTemplate` |
| `~/Library/Application Support/MarkView/lifecycle-events.jsonl` | Append-only JSON Lines, ISO 8601, sorted keys. No rotation in `LifecycleLog`; a project's lines are rewritten out when its delivery evidence is deleted | `LifecycleLog` |
| `~/Library/Application Support/MarkView/Projects/<ProjectPaths.projectCacheIdentifier>/` | SQLite fallback when `.dde/` can't be created | `SemanticDatabase` |
| `~/Library/Application Support/MarkView/login-<tool>.command`, `login-github.command` | zsh scripts (0755), never deleted | sign-in helpers |
| `~/Library/Application Support/MarkView/ProjectDrafts/<uuid>/` | `draft.json` (`ProjectDraft`, ISO 8601) and `workspace/docs/features/<slug>/` — a new project before its folder exists. Removed after a successful bootstrap or Discard. A build with another bundle ID uses `MarkView-<bundle id>/` | `ProjectDraftStore` |
| `~/Library/Caches/MarkView/pull-requests/<repo hash>/<label>/…` | file copies of the head and the base of a change; the label is `PR-<number>-<first 10 of head>`, `base-<first 10 of sha>` or `branch-<ref>` | `ChangeSource` (`cacheRoot`), `ChangeReviewStore.prFileURL` |
| `~/Library/Caches/MarkView/pasted-images/` | PNG, never cleaned | terminal paste (`TerminalSession`), browser element pick (`BrowserElementPick`), intake editor (`IntakeTextEditor`) |
| Unified log, subsystem `com.markview.app` | system log, not a file of the app | `AppLog` (see [runbook §5](./operations-runbook.md#5-logs)). `~/markview_debug.log` no longer exists |
| UserDefaults domain of the app bundle id | plist | see [configuration](./configuration.md) |
| WKWebView `localStorage` | key/value | see [configuration §2](./configuration.md#2-web-view-localstorage) |

## 3. Temporary

| Path | Notes |
|---|---|
| `$TMPDIR/markview_open_path.txt` (and `/tmp/markview_open_path.txt`) | Finder Quick Action handoff, polled by `FinderOpenRequests` (a `PollingScheduler` job). Opened with `O_NOFOLLOW`, verified via `fstat` (regular file owned by the current user, at most 64 KB), read, then deleted |
| `$TMPDIR/markview-cli/` | Working folder for CLI runs. Codex writes `schema-<uuid>.json` here and deletes it |
| `$TMPDIR/markview_whisper_<uuid>.wav` | Recording, deleted after transcription or cancel |
| `$TMPDIR/insight-export-<uuid>/` | Export staging, removed afterwards |

## 4. Read-only external data

| Path | Reader |
|---|---|
| `~/.claude/settings.json`, `~/.claude/projects/**/*.jsonl`, `~/.claude/.credentials.json` or Keychain item `Claude Code-credentials` | model defaults, agent usage |
| `~/.codex/config.toml`, `~/.codex/models_cache.json`, `~/.codex/auth.json`, `~/.codex/sessions/**`, `~/.codex/archived_sessions/**` | model list, agent usage, lifecycle model detection |

## 5. Compatibility rules

Under CLAUDE.md versioning, a change to the `.dde/` layout or to settings keys is a **major** bump.

- `.dde/state.db`: `PRAGMA user_version` is the number of the last applied step of `SemanticSchema.migrations`
  (`MarkViewCore.SQLiteMigration`, `AR-38`). Each step runs in one transaction that also writes `user_version`; throwing rolls the step
  back. A schema change is a new step at the end of the list, never an edit of a released one, and no step deletes data the index
  run cannot rebuild. A file whose `user_version` is higher than the app knows is refused (`SQLiteSchemaError`).
- JSON stores read through `SchemaVersionedStore` (`AR-36`) carry a schema version; a newer file is left untouched and reported.
- Settings keys are declared once in `SettingsKeys.swift` (see [configuration](./configuration.md)).
