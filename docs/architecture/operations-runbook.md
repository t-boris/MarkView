# Operations Runbook

Day-to-day procedures for building, running, debugging and releasing MarkView. For how the
build system is designed, see [build-release-testing](modules/build-release-testing.md). Other
modules: [app-shell-and-workspace](modules/app-shell-and-workspace.md) ·
[editor-and-bridge](modules/editor-and-bridge.md) ·
[ai-assistants-and-dictation](modules/ai-assistants-and-dictation.md) ·
[feature-workflow](modules/feature-workflow.md) ·
[architecture-and-xray](modules/architecture-and-xray.md) ·
[semantic-index-and-insight](modules/semantic-index-and-insight.md) ·
[git-github-terminal-lifecycle-usage](modules/git-github-terminal-lifecycle-usage.md)

> **Ground rule:** the installed `/Applications/MarkView.app` is usually in use, often with
> live Claude sessions in its terminals. Do not quit, kill or replace it without an explicit
> go-ahead in the same turn (`tasks/lessons.md:272-273`). Automated checks run against a build
> in `/tmp/MarkViewDerivedData` or `build/release` (`tasks/lessons.md:199-212`).

---

## 1. Build

```bash
# Debug, unsigned (standard verification build)
xcodebuild -project MarkView.xcodeproj -scheme MarkView \
  -configuration Debug -derivedDataPath /tmp/MarkViewDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

- Source: `CLAUDE.md` Verification. The product is
  `/tmp/MarkViewDerivedData/Build/Products/Debug/MarkView.app`.
- Check the editor bundle after a build:
  `ls .../MarkView.app/Contents/Resources/Editor/` must list `index.html`, `terminal.html` and
  `vendor/` (`tasks/lessons.md:268-270`).
- Changes confined to `EditorWeb/`: `cd EditorWeb && npm run type-check && npm run build`.
  This is not an app change (`CLAUDE.md` Project).
- After changing `tools/web-vendor/package.json`:
  `cd tools/web-vendor && npm ci && ./build.sh`, then rebuild the app
  (`tools/web-vendor/build.sh:3`).
- Version bump before committing an app change: `./bump-version.sh patch|minor|major`
  (`bump-version.sh:4`, `CLAUDE.md` Versioning).

## 2. Run a build without touching the user's app

```bash
open -n -a /tmp/MarkViewDerivedData/Build/Products/Debug/MarkView.app TestFiles/demo.md
```

- `open -n` with the DerivedData app together with the debug log is the verification method
  from `tasks/lessons.md:196-197`.
- On launch the app reopens the last folder (`workspace.lastFolder`,
  `MarkView/Models/WorkspaceManager.swift:447`). Before any scripted UI action, confirm that the
  key window shows your fixture, not the user's workspace (`tasks/lessons.md:208-211`).
- Stopping a test instance: in the **same** command, find the PID whose `ps -o command=`
  path is your build (for example `build/release/MarkView.app`) and kill only that one. Never
  kill by name, and never use a PID list from an earlier turn (`tasks/lessons.md:294-296`).

## 3. Run the standalone tests

| Command | Environment |
|---|---|
| `tools/tests/lifecycle-tests.sh` | any shell |
| `tools/tests/agent-usage-tests.sh` | any shell |
| `tools/tests/dictation-insertion-tests.sh` | logged-in GUI session; briefly opens a window |
| `tools/tests/transcription-failure-tests.sh` | any shell |
| `tools/tests/terminal-link-tests.sh [--open-browser]` | GUI session; `--open-browser` launches the default browser |
| `tools/importance-check.sh [claude\|codex] [model]` | signed-in AI CLI, costs tokens; **broken** until `:19` stops reading the removed `AIConsoleEngine.swift` |

All of them exit non-zero on failure. Details are in
[build-release-testing §11](modules/build-release-testing.md#11-test-strategy).

## 4. Debug a hang or beachball

1. Collect evidence before reading code (`CLAUDE.md` Working Rules,
   `tasks/lessons.md:101-118`):
   ```bash
   pgrep -x MarkView                   # choose the right PID if several builds run
   ps -o pid,%cpu,state,command -p <pid>
   /usr/bin/sample <pid> 3 -file /tmp/markview-sample.txt
   ```
2. Read **thread 0** (main thread) in the sample.
   - 0% CPU with state `S` means it is blocked (lock, IPC, `waitUntilExit`).
   - High CPU means a busy loop or heavy work on the main thread (`tasks/lessons.md:113-114`).
3. Use full paths `/usr/bin/sample` and `/usr/bin/log`. A shell wrapper in the zsh profile
   shadows the short names (`tasks/lessons.md:117-118`).
4. Known causes:
   - `Process.waitUntilExit()` on the main thread, or reading a pipe after waiting, which
     deadlocks once output exceeds 64 KB (`tasks/lessons.md:105-116`).
   - `DispatchQueue.main.sync` for each file during indexing (`tasks/lessons.md:137-138`).
5. For "slow" reports, first get the size of the delay and read the timestamps in the debug
   log. Seconds suggest parsing cost. Minutes suggest blocking or timeouts
   (`tasks/lessons.md:121-138`).

## 5. Logs

The app does **not** use `Logger` / `os_log` subsystems or categories: there is no `Logger(` or
`os_log(` call in `MarkView/`. It uses three channels:

| Channel | Location | Written by | Line prefix |
|---|---|---|---|
| Debug file log | `~/markview_debug.log` (appends, never rotated) | `WorkspaceManager.debugLog` (`MarkView/Models/WorkspaceManager.swift:436-446`), `[FileTree]` (`:192-203`), `[NSApp]` (`MarkView/App/MarkViewApp.swift:16-26`), `[AppDelegate]` (`:75-85`), `[Static]` (`:329-339`), indexer exit (`WorkspaceManager.swift:3020-3023`) | ISO-8601 timestamp, then tag |
| Insight diagnostics | `/tmp/markview-insight-diag.log`, plus stderr and NSLog | `WebViewBridge.logInsightDiag` (`MarkView/Bridge/WebViewBridge.swift:458-477`) | `[InsightDiag]` |
| `NSLog` (unified log, no subsystem) | Console.app / `log` | 111 calls. Tags: `[Insight]` 57, `[DDE]` 14, `[Whisper]` 6, `[StructuralIndexer]` 4, `[SemanticDB]` 2, `[Compiler]` 1, `[PDFExport]` 1 | tag in message |

```bash
tail -f ~/markview_debug.log
/usr/bin/log stream --process MarkView --style compact
/usr/bin/log show --last 10m --process MarkView --predicate 'eventMessage CONTAINS "[Whisper]"'
```

- Web Inspector: `developerExtrasEnabled` is set on the editor web view
  (`MarkView/Views/EditorView.swift:19`). Right-click the editor and choose Inspect Element.
- Never log API keys or any part of them, only whether a key exists and its length
  (`tasks/lessons.md:177-179`, `CLAUDE.md` Working Rules).

## 6. Where state lives and how to reset it

Quit the instance you are resetting first. Never reset the user's live app without asking.

| State | Location | Source |
|---|---|---|
| Preferences (layout, theme, sort order, AI backend, CLI extra PATH, GitHub settings, Whisper model, custom AI filters, last folder) | UserDefaults domain `com.markview.MarkView` | bundle id `project.pbxproj:584`. Keys include `layout.*`, `settings.ai.backend`, `settings.cli.extraPATH` (`MarkView/Models/AIAssistants.swift:219`), `settings.github.*`, `settings.whisper.model`, `ai.customFilters`, `workspace.lastFolder` |
| OpenAI API key (Whisper, embeddings), stored in plain text | same domain, key `com.markview.dde.openai.apikey` | `MarkView/Models/WhisperClient.swift:26`, `MarkView/Models/EmbeddingClient.swift:125` |
| Per-folder index (SQLite + FTS5), caches, overlays | `<folder>/.dde/` (`state.db`, `cache/`, `overlays/`), git-ignored (`.gitignore:34-35`) | `MarkView/Models/SemanticDatabase.swift:12-31` |
| Index fallback when `.dde/` cannot be created | `~/Library/Application Support/MarkView/<folder-name>/` | `SemanticDatabase.swift:21-26` |
| Recent files | `~/Library/Application Support/MarkView/recentFiles.json` | `WorkspaceManager.swift:403-406` |
| Lifecycle events (append-only, shared by all windows) | `~/Library/Application Support/MarkView/lifecycle-events.jsonl` | `MarkView/Models/LifecycleLog.swift:23-24` |
| CLI login helpers | `~/Library/Application Support/MarkView/login-*.command` | `AIAssistants.swift:496-498`, `MarkView/Views/GitHubViews.swift:1406-1408` |
| PR X-Ray file copies | `~/Library/Caches/MarkView/pull-requests/<hash>/<label>/` | `MarkView/Models/ArchitectureStore.swift:1943-1947` |
| Pasted terminal images | `~/Library/Caches/MarkView/pasted-images/` | `MarkView/Models/TerminalSession.swift:349-350` |
| Temp files | `$TMPDIR/markview-cli/` (empty cwd for CLI runs), `$TMPDIR/insight-v1-compat/`, `$TMPDIR/markview_whisper_<uuid>.wav` | `MarkView/Models/CLICompletion.swift:167-171`, `MarkView/Models/InsightSession.swift:312-313`, `WhisperClient.swift:97` |
| Legacy sandbox container | `~/Library/Containers/com.markview.MarkView/` (from before the sandbox was turned off) | `install.sh:18` |

Resets:

```bash
defaults read com.markview.MarkView                      # inspect first
defaults delete com.markview.MarkView workspace.lastFolder   # stop reopening the last folder
defaults delete com.markview.MarkView                    # all preferences, INCLUDING the OpenAI key
rm -rf <folder>/.dde                                     # rebuild that folder's index on next open
rm -rf ~/Library/Caches/MarkView                         # PR copies, pasted images
```

Before deleting `lifecycle-events.jsonl`, keep a copy: it is the only record of lifecycle
history. The `.dde/` layout and settings keys are stored data, so an incompatible change to
them is a major version bump (`CLAUDE.md` Versioning).

## 7. Common failures and fixes

| Symptom | Cause and fix | Source |
|---|---|---|
| Beachball when opening a large folder | Synchronous `Process`/git on the main thread, or pipe read after `waitUntilExit`. Run child processes off the main thread and drain pipes concurrently | `tasks/lessons.md:101-118` |
| Child process `terminationHandler` never fires | The `Process` was released. Hold it in a static, process-wide collection until the handler runs | `tasks/lessons.md:140-151` |
| Codex/Claude "does nothing" | Hard-coded CLI path. Resolve in order: settings override → candidates including every `~/.nvm/versions/node/*/bin` → login shell. Check sign-in with `claude auth status` / `codex login status` | `tasks/lessons.md:153-175`, `AIAssistants.swift:273-282` |
| Codex run shows an "error" but works | `{"type":"error"}` events can be warnings; only `turn.failed` is fatal | `tasks/lessons.md:251-253` |
| Crash (SIGTRAP) at launch after toolbar changes | `@EnvironmentObject` inside `.toolbar`. Pass objects as parameters, and launch the built app to verify | `tasks/lessons.md:45-53` |
| Menu item stuck enabled or disabled | Menu state read from an object behind `@FocusedValue`. Use a value-typed `focusedSceneValue` | `tasks/lessons.md:214-227` |
| Finder "Open With" opens nothing | Notification sent before the window attached. Queue external requests durably and drain them | `tasks/lessons.md:181-197` |
| Blank editor or terminal web view | New file in `Resources/Editor` not copied by the pre-build script | `tasks/lessons.md:268-270` |
| "no column named ..." after an upgrade | Column added without a migration. Use `addMissingColumns` in `createTables` | `tasks/lessons.md:247-249` |
| Editor panel will not hide | CSS `display` overrides `[hidden]`. Add `[hidden]{display:none}` (with `!important` for CodeMirror) and check in WebKit | `tasks/lessons.md:255-257` |
| Terminal link opens nothing or triggers TUI clicks | OSC 8 links need `linkHandler`; reserve Cmd+click; resolve against the live cwd | `tasks/lessons.md:310-317` |
| Dictation keeps the microphone on or writes into the wrong field | Capture a generation token and the originating window | `tasks/lessons.md:298-307` |
| Recording lost when switching tabs | Long-lived work owned by `@StateObject` of a transient view. Move it to the model | `tasks/lessons.md:25-32` |
| Memory spike while scanning agent logs | Read in 8 MB chunks inside `autoreleasepool`; measure with `/usr/bin/time -l` | `tasks/lessons.md:286-291` |
| "0%" / "1%" usage windows vanish | `NSNumber` matches `is Bool`. Use `CFBooleanGetTypeID` | `tasks/lessons.md:281-284` |
| `.md` from the PR cache switches the workspace | Files the app places outside the folder must count as part of the workspace (`isFileInCurrentWorkspace`) | `tasks/lessons.md:55-63` |
| First launch blocked by Gatekeeper | DMG not notarized. Use "Open Anyway", or release with `NOTARY_PROFILE` | `release.sh:7-9`, `README.md:147-149` |
| `release.sh` exits with "No Developer ID Application identity found" | No certificate in the keychain. Install one or set `SIGN_IDENTITY` | `release.sh:14-15` |
| `importance-check.sh` fails in the python step | `AIConsoleEngine.swift` no longer exists; the helpers are in `AIAssistants.swift` | `tools/importance-check.sh:19` |

Process lessons that affect operations:
- Never use `git stash` to compare versions. Use `git show HEAD:path > /tmp/...` or a worktree
  (`tasks/lessons.md:264-266`).
- Before deleting a range or a whole file, list its top-level declarations
  (`tasks/lessons.md:229-241`).

## 8. Release checklist

1. The working tree holds only the intended changes (`git status`). Credentials and `.dde/` are
   not staged (`CLAUDE.md` Working Rules, `.gitignore:34-35`).
2. The version is bumped at the right semver level. `project.yml` and both pbxproj configurations
   agree (`bump-version.sh:19-22`); check with
   `grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' project.yml MarkView.xcodeproj/project.pbxproj`.
3. If vendored JS changed: run `tools/web-vendor` `npm ci && ./build.sh` and commit the outputs.
4. The Debug build passes and the relevant `tools/tests/*.sh` pass (sections 1 and 3).
5. Build the release artifact **without** installing:
   ```bash
   NOTARY_PROFILE=<profile> ./release.sh    # or without NOTARY_PROFILE: signed, not notarized
   ```
   Output: `build/MarkView-<version>.dmg` and its SHA-256 (`release.sh:19`, `:46`). Optional:
   `SIGN_IDENTITY="Developer ID Application: …"` (`release.sh:14`).
6. Smoke-test `build/release/MarkView.app` with `open -n`, then stop only that PID (section 2).
7. Commit and push. The push to `main` also triggers CI, which replaces the `latest` GitHub
   release with an ad-hoc-signed zip (`.github/workflows/build-release.yml:3-5`, `:42-66`).
8. Publish the DMG by hand under a `v<version>` tag (existing tags: `v2.12.0`, `v2.15.0`, …). No
   script does this.
9. Install only when the user asks in that turn. `./release.sh --install` and `./install.sh` quit
   the running app (`release.sh:51-53`, `install.sh:5-7`). If the command runs inside a MarkView
   terminal, the quit kills the script before the copy. Build with `./release.sh`, then run the
   install steps (quit, attach the DMG, `ditto` to `/Applications`, open) detached, for example
   with `nohup bash -c '…' >/tmp/mv-install.log 2>&1 &`, and say beforehand that the session will
   restart (project memory `install-detached.md`).

### Environment variables used by scripts

| Variable | Used in | Effect |
|---|---|---|
| `SIGN_IDENTITY` | `release.sh:14` | overrides the auto-detected Developer ID identity |
| `NOTARY_PROFILE` | `release.sh:41-44` | `notarytool` keychain profile; turns on notarization and stapling |
| `TARGET_BUILD_DIR`, `UNLOCALIZED_RESOURCES_FOLDER_PATH`, `SRCROOT` | pre-build script, `project.yml:42-48` | Xcode build settings; destination of the editor copy |
| `HOME` | `install.sh:18` | locates the legacy sandbox container plist |
| `GH_TOKEN` (`secrets.GITHUB_TOKEN`), `GITHUB_OUTPUT`, `GITHUB_WORKSPACE`, `github.sha` | `.github/workflows/build-release.yml:30-45`, `:58`, `:67-68` | CI release publishing |
