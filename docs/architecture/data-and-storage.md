# Data and Storage

This page lists everything MarkView persists, grouped by location. Schemas are in the owning
module doc.

## 1. Inside the workspace (per project)

| Path | Format | Owner | Notes |
|---|---|---|---|
| `.dde/state.db` (+ `-wal`, `-shm`) | SQLite 3, WAL, FTS5, `user_version=1` | `SemanticDatabase` | Documents, blocks, symbols, relations, FTS, token usage, `arch_*` X-Ray tables. About 20 tables are never populated. Schema: [semantic §6.2](./modules/semantic-index-and-insight.md#62-tables), [X-Ray §6.1](./modules/architecture-and-xray.md#61-project-x-ray-sqlite-ddestatedb) |
| `.dde/file_<name>.db` | SQLite | `SemanticDatabase` | Single-file workspace, in the file's parent folder |
| `.dde/cache/{provider_responses,embeddings,indexes}`, `.dde/overlays` | directories | `WorkspaceManager` | Created on open, but nothing writes to them |
| `.dde/cache/xray/<sha>.json` | JSON | `ArchitectureStore` | AI answer cache |
| `.dde/cache/xray/terms-<sha24>.json` | JSON | `FilterSearch` | AI filter search terms |
| `.dde/cache/xray-content/<sha(abs path)>.json` | JSON | `XRayContent` | File outlines. Folder X-Rays write these inside the scanned folder |
| `.dde/cache/explain/<sha256(path)[:24]>.json` | JSON | `CodeExplainStore` | Explain margin notes |
| `.dde/xray-folders/<sha24>.json` | JSON | `ArchitectureStore` | Folder X-Ray snapshots |
| `.markview-insight/` (`nodes/<UUID>.html`, `manifest.json`, `snapshot.json`, `_assets/**`) | HTML/JSON + copied vendor JS | `InsightCache` | Kept after the tab closes. The root id is the SHA-256 of the folder path, so moving the folder orphans it |
| `docs/features/<slug>/` | Markdown + YAML front matter | `FeatureStore` | `overview.md`, `discussion.md`, `requirements/REQ-nnn.md`, `questions/Q-nnn.md`, `decisions/DEC-nnn.md`, `findings/F-nnn.md`, `research/R-nnn.md`, `references/SRC-nnn*.md`, `implementation/plan.md`, `diagrams/*.md`. Schema: [feature-workflow §6](./modules/feature-workflow.md#62-front-matter-fields) |
| `docs/bugs/BUG-nnn-<slug>.md`, `docs/bugs/assets/` | Markdown + YAML | `FeatureStore` | Bug reports with `BQ-n` questions |
| `docs/research/RES-nnn-<slug>.md` | Markdown + YAML | `ArchitectureStore` | Saved ⚡ search answers |
| `.claude/CLAUDE.md` | Markdown | generated context | Deleted by Remove Metadata only if it starts with the generated header |
| `.gitignore` | text | `FileTreeView` | Appended from the file tree menu |

All of `.dde/` and `.markview-insight/` can be regenerated. Deleting them
(**File ▸ Remove Metadata…**) loses X-Ray AI groupings and descriptions, Explain notes and Insight
documents, but no user content.

## 2. Per user (`~`)

| Path | Format | Owner |
|---|---|---|
| `~/Library/Application Support/MarkView/recentFiles.json` | JSON array (≤20). Written but never read by the UI | `WorkspaceManager` |
| `~/Library/Application Support/MarkView/lifecycle-events.jsonl` | Append-only JSON Lines, ISO 8601, sorted keys. Never rotated | `LifecycleLog` |
| `~/Library/Application Support/MarkView/<folder>/` | SQLite fallback when `.dde/` can't be created | `SemanticDatabase` |
| `~/Library/Application Support/MarkView/login-<tool>.command`, `login-github.command` | zsh scripts (0755), never deleted | sign-in helpers |
| `~/Library/Application Support/MarkView/ProjectDrafts/<uuid>/` | `draft.json` (`ProjectDraft`, ISO 8601) and `workspace/docs/features/<slug>/` — a new project before its folder exists. Removed after a successful bootstrap or Discard. A build with another bundle ID uses `MarkView-<bundle id>/` | `ProjectDraftStore` |
| `<project>/.dde/github-connection.json` | `GitHubConnectionRecord`: target, visibility, created/committed/pushed. Deleted once connected | `GitHubPublisher` |
| `~/Library/Caches/MarkView/pull-requests/<hash>/PR-<n>-<head>/…`, `base-<sha>/…` | file copies | PR X-Ray |
| `~/Library/Caches/MarkView/pasted-images/image-<ms>.png` | PNG, never cleaned | terminal paste |
| `~/markview_debug.log` | text, never rotated, includes file paths | `debugLog` |
| UserDefaults domain of the app bundle id | plist | see [configuration](./configuration.md) |
| WKWebView `localStorage` | key/value | see [configuration §2](./configuration.md#2-web-view-localstorage) |

## 3. Temporary

| Path | Notes |
|---|---|
| `/tmp/markview_open_path.txt` | Finder Quick Action handoff. Read, then deleted. World-writable location |
| `/tmp/markview-insight-diag.log` | Insight and bridge diagnostics. World-readable, unbounded, contains content prefixes |
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
The SQLite schema version is `PRAGMA user_version = 1`, and there is no migration framework beyond
`CREATE TABLE IF NOT EXISTS`. Any column change needs an explicit migration step in
`SemanticDatabase`.
