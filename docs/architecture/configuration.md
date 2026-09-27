# Configuration

MarkView has no config file. Configuration is split across UserDefaults (set through the DDE
Settings window and UI toggles), web view `localStorage`, command-line flags, the environment of
child processes, and build-time settings.

## 1. UserDefaults keys

Changing or renaming any of these keys is a **major** version change (CLAUDE.md).

| Key | Type / default | Purpose | Owner |
|---|---|---|---|
| `workspace.lastFolder` | path | Folder restored on launch | app shell |
| `layout.showFileTree`, `layout.showTOC` | Bool | Pane visibility | app shell |
| `layout.leftPanelWidth` | Double, 220 (180–800) | Width of the left pane (Files and Issues), restored on launch | app shell |
| `layout.navigatorTab`, `layout.leftPanel`, `layout.issuesFeature`, `layout.gitSection`, `layout.terminalPromptsExpanded` | enum/String/Bool | Panel state | app shell, features, git, terminal |
| `feature.stage`, `feature.lifecycle.expanded` | String/Bool | Feature panel state (global across windows) | features |
| `features.active.<12-char hash of root>` | String | Open feature per project | features |
| `features.issues.filter.<12-char hash of root>` | [String], `[]` | Issues list funnel filter per project: ids of `open`, `closed`, `bugs`, `features`, `implemented`, `not-implemented`; unknown ids ignored | features |
| `features.issues.sort.<12-char hash of root>` | String, `date:desc` | Issues list order per project, `date\|priority:asc\|desc`; unknown values fall back to the default | features |
| `fileTree.sortField`, `fileTree.sortAscending` | enum/Bool | File tree sort | app shell |
| `excludedFolders.<folderName>` | [String] | Excluded folders. Keyed by folder name only | app shell |
| `theme` | light/dark/system | Theme | `ThemeManager` |
| `settings.ai.backend` | `CLITool` raw value | Selected assistant | AI |
| `settings.cli.<tool>Model`, `settings.xray.<tool>Model` | String | Model per tool; X-Ray has its own (defaults `sonnet` / `gpt-5.6-luna`) | AI |
| `settings.cli.<tool>Path`, `settings.cli.extraPATH` | String | CLI path override, extra PATH entries for subprocesses | AI |
| `settings.cli.{cline,copilot}Models` | JSON | Cached ACP model lists | AI |
| `actions.outputLanguage` | String | Language for AI output and translation | AI |
| `ai.customFilters` | JSON | User-defined X-Ray AI filters | X-Ray |
| `settings.whisper.model` | `whisper-1` / `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` | Dictation model | dictation |
| `com.markview.dde.openai.apikey` | String, **plaintext** | OpenAI key (Whisper, key check) | settings |
| `settings.github.enabled` | Bool, `false` | Master switch for GitHub integration | GitHub |
| `settings.github.idleInterval` / `activeInterval` | seconds, 300 / 30 | Poll intervals | GitHub |
| `settings.github.notifyRuns`, `settings.github.autoReview` | Bool, `true` | CI notifications, auto PR X-Ray | GitHub |
| `settings.usage.{claude,codex}.hidden` | Bool | Hide (and stop polling) an agent's quota chip | agent usage |
| `settings.usage.{claude,codex}.limit` | JSON `FallbackLimit` | Manual quota fallback | agent usage |
| `lifecycle.models` | JSON | Detected model per lifecycle job | lifecycle |

To reset: quit the app, then `defaults delete <bundle id>` (see the
[runbook](./operations-runbook.md)).

## 2. Web view localStorage

| Key | Purpose |
|---|---|
| `markview-theme`, `markview-font-size` | Editor appearance |
| `markview-code-notes-width` | Explain notes pane width |
| `markview-xray-details-width`, `markview-xray-details-hidden` | X-Ray details panel ("explanations") |

## 3. Command-line flags

| Flag | Effect |
|---|---|
| `--dde-index <folder>` | Headless structural indexer child process, used internally by `runStructuralIndex` |

## 4. Environment

The app reads no environment variables of its own. It **sets** these for child processes:

| Process | Variables |
|---|---|
| All CLI subprocesses | `PATH` replaced by `CLIToolLocator.subprocessPath` (extra PATH + login-shell PATH) |
| `gh` | `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `NO_COLOR=1`, `GIT_TERMINAL_PROMPT=0`, stdin `/dev/null` |
| `git` via `GitHubClient` / PR fetch | `GIT_TERMINAL_PROMPT=0` (not set by `GitClient`) |
| Terminal shell | `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=MarkView`, `LANG` if unset, `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`. Removes `CLAUDECODE` and `CLAUDE_CODE_*` |

Scripts read `SIGN_IDENTITY` and `NOTARY_PROFILE` (`release.sh`) and `HOME` (`install.sh`). CI uses
`GH_TOKEN`. See [build-release-testing](./modules/build-release-testing.md).

## 5. Hard-coded limits worth knowing

| Limit | Value | Where |
|---|---|---|
| Insight prompt caps | 50 KB/file, 200 KB/group, 600 KB inline before catalog mode, 5 concurrent sections | [semantic §5.4](./modules/semantic-index-and-insight.md#54-recursive-insight-session-lifecycle) |
| Translation chunk | ≤4000 chars, 240 s timeout | [app-shell §5.8](./modules/app-shell-and-workspace.md#58-document-translation) |
| Dictation | 10 min recording cap, 30 s warning | [ai-assistants §6.5](./modules/ai-assistants-and-dictation.md#65-dictation-record--transcribe--insert-intake-sheet) |
| Agent usage | stale after 15 min, backoff 5→30 min, manual cooldown 60 s, levels 80/95 % | [usage §D](./modules/git-github-terminal-lifecycle-usage.md) |

## 6. Build-time configuration

- `project.yml` is the source of truth. `MARKETING_VERSION` equals `CURRENT_PROJECT_VERSION`, and
  both are set by `./bump-version.sh`.
- `MarkView/Info.plist`: document types, usage strings (microphone, Apple Events), and
  **ATS arbitrary loads allowed**.
- Entitlements: **App Sandbox off** in both configurations. Release adds audio input and Apple Events;
  Debug adds audio input and network client.

Details: [build-release-testing](./modules/build-release-testing.md).
