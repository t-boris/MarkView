# Configuration

Checked against the code at `ac3001ba` (2026-11-15).

MarkView has no config file. Configuration is split across UserDefaults (set through the DDE
Settings window and UI toggles), web view `localStorage`, command-line flags, the environment of
child processes, and build-time settings.

## 1. UserDefaults keys

Changing or renaming any of these keys is a **major** version change (CLAUDE.md). Every key is declared once in
`Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift` (`SettingsKey`, with a scope `.app`, `.project` or `.window`), and lint rule
`settings-literal` keeps a key literal out of the rest of the app. That file is the complete list (70 literal keys plus the keys built
from a tool, an agent or a project root); the tables below list the ones people ask about, and the last table lists keys added since.

| Key | Type / default | Purpose | Owner |
|---|---|---|---|
| `workspace.lastFolder` | path | Folder restored on launch | app shell |
| `layout.showTOC.v3` | Bool | Contents section visibility. The left panel has no stored default: every new window starts with it closed (center panel only) and a window restores its own from its saved session | app shell |
| `layout.leftPanelWidth`, `layout.rightPanelWidth` | Double, 220 (180–6000) / 500 (320–1200) | Width of the left / right pane. The window keeps its own (`WindowUIState`); the key is only the starting value of a new window | app shell |
| `layout.navigatorTab`, `layout.leftPanel`, `layout.issuesFeature`, `layout.gitSection`, `feature.stage` | enum/String | Last panel tab/section chosen. Each window keeps its own in `PanelLayout`; the key only seeds the next window and relaunch (BUG-004) | app shell, features, git |
| `contents.infoExpanded`, `search.panelMode`, `uiStudioInspectorWidth`, `uiStudioSelectionExpanded`, `prototypeChatWidth`, `prototypePickScreenshot`, `imageSlideshowSeconds`, `editorTextSizeMirror`, `fileBrowser.viewMode`, `fileBrowser.showHidden`, `fileBrowser.hideIgnored`, `fileBrowser.category` | mixed | Per-window interface state (`WindowUIState`); the key is only the starting value of a new window | app shell |
| `features.active.<12-char hash of root>` | String | Open feature per project | features |
| `research.webDisabled.<12-char hash of root>` | Bool, false | New Research: repository-only, no web search, for this folder (DEC-011) | research |
| `research.timeoutMinutes` | Int, 20 (5–120) | New Research job time limit; a longer run stops and is saved as incomplete (DEC-012) | research |
| `features.issues.filter.<12-char hash of root>` | [String], `[]` | Issues list funnel filter per project: ids of `open`, `closed`, `bugs`, `features`, `implemented`, `not-implemented`; unknown ids ignored | features |
| `features.issues.sort.<12-char hash of root>` | String, `date:desc` | Issues list order per project, `date\|priority:asc\|desc`; unknown values fall back to the default | features |
| `fileTree.sortField`, `fileTree.sortAscending` | enum/Bool | File tree sort | app shell |
| `excludedFolders.<project path>` | [String] | Excluded folders of one project, keyed by its full path (a list under the folder-name key is copied once) | app shell |
| `theme` | light/dark/system | Legacy theme: read once to start a window in Classic Light or Classic Dark; never written | `ThemeSettingsStore` |
| `theme.lastChanged.v1` | JSON | Theme and per-theme accents last chosen in any window; the start of a new window | `ThemeSettingsStore` |
| `settings.ai.backend` | `CLITool` raw value | Selected assistant | AI |
| `settings.cli.<tool>Model`, `settings.xray.<tool>Model` | String | Model per tool; X-Ray has its own (defaults `sonnet` / `gpt-5.6-luna`) | AI |
| `settings.cli.<tool>Path`, `settings.cli.extraPATH` | String | CLI path override, extra PATH entries for subprocesses | AI |
| `settings.cli.{cline,copilot}Models` | JSON | Cached ACP model lists | AI |
| `actions.outputLanguage` | String | Language for AI output and translation | AI |
| `ai.customFilters` | JSON | User-defined X-Ray AI filters | X-Ray |
| `xray.autoAnalyze` | Bool, `true` | Automatic code analysis of code projects when they open and after code changes (DEC-001 of automatic-code-architecture). Off: only the local layers, no CLI agent is started | X-Ray |
| `settings.whisper.model` | `whisper-1` / `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` | Dictation model | dictation |
| `com.markview.dde.openai.apikey` | String, **plaintext** | OpenAI key (Whisper, key check) | settings |
| `settings.github.enabled` | Bool, `false` | Master switch for GitHub integration. Also turned on by a completed Publish to GitHub (DEC-020 of start-a-project-from-scratch) | GitHub |
| `newProject.parentFolder` | path, `~/Developer` else `~/Documents` | Last parent folder chosen for a new project (Start a Project from Scratch) | new project |
| `settings.github.idleInterval` / `activeInterval` | seconds, 300 / 30 | Poll intervals | GitHub |
| `settings.github.notifyRuns`, `settings.github.autoReview` | Bool, `true` | CI notifications, auto PR X-Ray | GitHub |
| `settings.usage.{claude,codex}.hidden` | Bool | Hide (and stop polling) an agent's quota chip | agent usage |
| `settings.usage.{claude,codex}.limit` | JSON `FallbackLimit` | Manual quota fallback | agent usage |
| `lifecycle.models` | JSON | Detected model per lifecycle job | lifecycle |

To reset: quit the app, then `defaults delete <bundle id>` (see the
[runbook](./operations-runbook.md)).

Keys declared in `SettingsKeys.swift` that the tables above do not cover (the type and default are those of the declaration; scope
`project` means one value per project key, `window` means a window's own value):

| Key | Type / default | Scope | Purpose |
|---|---|---|---|
| `appFontScalePercent` | Int, 100 | app | Application font scale |
| `browser.openTerminalLinksInApp` | Bool, `true` | app | Open terminal links in the built-in browser |
| `browserNeverSavePasswordHosts` | [String], `[]` | app | Hosts the person said never to save a password for |
| `pdfExport.theme`, `pdfExport.paper` | String, `paper` / `a4` | app | PDF export theme and paper size |
| `workspace.recentProjects` | [String], `[]` | app | Recently opened folders, most recent first |
| `settings.dictation.locale` | String, `""` | app | Dictation language as a BCP 47 identifier (`""` follows the system) |
| `settings.github.activeInterval` | Double, 30 | app | Seconds between checks while a run is active |
| `settings.github.configDirectory` | String, `""` | app | The `gh` configuration folder the person chose |
| `qaRecordVideo`, `qaReviewDepth` | Bool `true` / String `screens` | app | QA run options |
| `remote.relayURL`, `remote.deviceID` | String, `""` | app | Remote workspace relay and device id |
| `project.ai` | JSON | project | One project's assistant, model and X-Ray model choices |
| `project.colors`, `project.colors.byFolderName` | JSON / Bool | project | A chosen colour per project; the second is set once colours saved before DEC-014 were dropped |
| `project.workspaceTransparency`, `project.linkedFolders` | JSON | project | Workspace transparency and linked folders per project |
| `layout.showTOC.v3` | Bool, `false` | app | Starting value for the Contents section |
| `layout.workspaceArea`, `layout.workSection` | String, `Files` / `Tasks` | window | Area and work section shown by the window |
| `layout.agentsWidth`, `layout.agentsHeight`, `layout.agentsOffsetX`, `layout.agentsOffsetY` | Double, 650 / 600 / 0 / 0 | window | Geometry of the agents panel |
| `welcomeBackdrop` | String, `matrix` | window | Backdrop of the welcome screen |
| `qa.panel`, `qa.inspectorWidth`, `qa.showApps`, `qa.showPlayers`, `qa.showEnvironments`, `qa.showBaseline` | String `branches` / Double 380 / Bool `true`, `true`, `true`, `false` | window | QA tab layout and filters |

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
| `--mcp-browser` | MCP stdio server with the browser tools, started by an agent's MCP configuration (`BrowserAgentTools.runServer`); never returns |
| `--mcp-project` | MCP stdio server with the project tools (`ProjectAgentTools.profile`); never returns |
| `--mcp-control` | MCP stdio server with the control tools (`ControlAgentTools.profile`); never returns |
| `--project-call` | Runs one project tool call from the command line and exits (`ProjectAgentTools.runCall`) |
| `--remote-workspace-mcp`, `--remote-workspace-guard` | The remote-workspace MCP server and its command guard (`RemoteUnixRPC.runMCP`, `runGuard`); never return |

## 4. Environment

The app reads no environment variables of its own. It **sets** these for child processes:

| Process | Variables |
|---|---|
| All CLI subprocesses | `PATH` replaced by `CLIToolLocator.subprocessPath` (extra PATH + login-shell PATH) |
| `gh` | `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `NO_COLOR=1`, `GIT_TERMINAL_PROMPT=0`, stdin `/dev/null` |
| `git` via `GitHubClient` / PR fetch | `GIT_TERMINAL_PROMPT=0` (not set by `GitClient`) |
| Terminal shell | `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=MarkView`, `LANG` if unset, `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`. Removes `CLAUDECODE` and `CLAUDE_CODE_*` |

Scripts read `SIGN_IDENTITY`, `NOTARY_PROFILE` and the optional `NOTARY_KEYCHAIN` (`release.sh`). CI uses `GH_TOKEN`. See [build-release-testing](./modules/build-release-testing.md).

## 5. Hard-coded limits worth knowing

| Limit | Value | Where |
|---|---|---|
| Insight prompt caps | 50 KB/file, 200 KB/group, 600 KB inline before catalog mode, 5 concurrent sections | [semantic §5.4](./modules/semantic-index-and-insight.md#54-recursive-insight-session-lifecycle) |
| Translation chunk | ≤4000 chars, 240 s timeout | [app-shell §5.8](./modules/app-shell-and-workspace.md#58-document-translation) |
| Dictation | 10 min recording cap, 30 s warning | [ai-assistants §6.5](./modules/ai-assistants-and-dictation.md#65-dictation-record--transcribe--insert-intake-sheet) |
| Agent usage | stale after 15 min, backoff 5→30 min, manual cooldown 60 s, levels 80/95 % | [usage §D](./modules/git-github-terminal-lifecycle-usage.md) |
| Automatic code analysis | 60 s of quiet after a change, AI runs ≥15 min apart, ≤5000 source files (DEC-003) | `AutoAnalysisScheduler`, [X-Ray](./modules/architecture-and-xray.md) |

## 6. Build-time configuration

- `MarkView.xcodeproj/project.pbxproj` is the single source of truth (XcodeGen has been retired). `MARKETING_VERSION` equals `CURRENT_PROJECT_VERSION`, and both are set by `./bump-version.sh`.
- `MarkView/Info.plist`: document types, usage strings (microphone, Apple Events), and
  App Transport Security: `NSAllowsArbitraryLoads` is false; web content (`NSAllowsArbitraryLoadsInWebContent`) and local networking (`NSAllowsLocalNetworking`) are allowed (AR-41).
- Entitlements: **App Sandbox off** in both configurations. Release adds audio input and Apple Events;
  Debug adds audio input and network client.

Details: [build-release-testing](./modules/build-release-testing.md).
