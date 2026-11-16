# Operations Runbook

Checked against the code at `ac3001ba` (2026-11-15). The commands were read, not run, in that check.

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
> go-ahead in the same turn (`tasks/lessons.md`). Automated checks run against a build
> in `/tmp/MarkViewDerivedData` or `build/release` (`tasks/lessons.md`).

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
  `vendor/` (`tasks/lessons.md`).
- Changes confined to `MarkView/Resources/Editor/`: validate syntax (`node --check`) and re-run `xcodebuild`.
- After changing `tools/web-vendor/package.json`:
  `cd tools/web-vendor && npm ci && ./build.sh`, then rebuild the app
  (`tools/web-vendor/build.sh`).
- Version bump before committing an app change: `./bump-version.sh patch|minor|major`
  (`bump-version.sh`, `CLAUDE.md` Versioning).

## 2. Run a build without touching the user's app

```bash
open -n -a /tmp/MarkViewDerivedData/Build/Products/Debug/MarkView.app TestFiles/demo.md
```

- `open -n` with the DerivedData app together with the debug log is the verification method
  from `tasks/lessons.md`.
- On launch the app restores each window's saved session, or the last folder (`workspace.lastFolder`) when there is none
  (`MarkView/Models/Workspace/WindowSessionController.swift`). Before any scripted UI action, confirm that the
  key window shows your fixture, not the user's workspace (`tasks/lessons.md`).
- Stopping a test instance: in the **same** command, find the PID whose `ps -o command=`
  path is your build (for example `build/release/MarkView.app`) and kill only that one. Never
  kill by name, and never use a PID list from an earlier turn (`tasks/lessons.md`).

## 3. Run the tests

| Command | What it runs |
|---|---|
| `swift test --package-path Packages/MarkViewCore` | the `MarkViewCoreTests` of the local package |
| `./tools/lint/architecture-lint.sh` | the structural gate (rules and ratchets, allow-lists in `tools/lint/*.txt`) |
| `./tools/tests/run.sh --tier pure` | the pure standalone suites (CLI only) |
| `./tools/tests/run.sh --changed` | the suites whose sources changed; exit 3 means files changed and no suite covers them |
| `./tools/tests/run.sh <name>` | one suite from `tools/tests/manifest.json` (`--list` prints them) |
| `./tools/tests/run.sh --tier gui` | suites that open a window or WebKit; run in a logged-in GUI session |
| `./tools/tests/run.sh --tier live` | suites that need a signed-in assistant or the network; they cost tokens |

All of them exit non-zero on failure. Details are in
[build-release-testing §11](modules/build-release-testing.md#11-test-strategy).

## 4. Debug a hang or beachball

1. Collect evidence before reading code (`CLAUDE.md` Working Rules,
   `tasks/lessons.md`):
   ```bash
   pgrep -x MarkView                   # choose the right PID if several builds run
   ps -o pid,%cpu,state,command -p <pid>
   /usr/bin/sample <pid> 3 -file /tmp/markview-sample.txt
   ```
2. Read **thread 0** (main thread) in the sample.
   - 0% CPU with state `S` means it is blocked (lock, IPC, `waitUntilExit`).
   - High CPU means a busy loop or heavy work on the main thread (`tasks/lessons.md`).
3. Use full paths `/usr/bin/sample` and `/usr/bin/log`. A shell wrapper in the zsh profile
   shadows the short names (`tasks/lessons.md`).
4. Known causes:
   - `Process.waitUntilExit()` on the main thread, or reading a pipe after waiting, which
     deadlocks once output exceeds 64 KB (`tasks/lessons.md`).
   - `DispatchQueue.main.sync` for each file during indexing (`tasks/lessons.md`).
5. For "slow" reports, first get the size of the delay and read the timestamps in the debug
   log. Seconds suggest parsing cost. Minutes suggest blocking or timeouts
   (`tasks/lessons.md`).

## 5. Logs

The app logs through `AppLog` (`Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift`, `AR-24`): one `os.Logger` per area under
the subsystem `com.markview.app`. There is no `NSLog` or `print` call in `MarkView/`, and no log file.

| Channel | Location | Written by |
|---|---|---|
| Unified log, subsystem `com.markview.app` | Console.app / `log` | `AppLog.<category>`: `app`, `app-delegate`, `finder`, `file-tree`, `workspace`, `window-session`, `store`, `bridge`, `insight`, `index`, `dictation`, `browser` |

A message's level is `error`, `notice` or `debug`; a dynamic string (a path, a name, a child's error) is private by default and
shows as `<private>` unless private data is turned on. Debug messages are not kept unless you stream them.

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "com.markview.app"' --style compact
/usr/bin/log show --last 10m --predicate 'subsystem == "com.markview.app" AND category == "index"'
```

- Web Inspector: `developerExtrasEnabled` and `isInspectable` are set on every web view made through `WebHost`
  (`Packages/MarkViewCore/Sources/MarkViewCore/WebHost.swift`). Right-click the editor and choose Inspect Element.
- Never log API keys or any part of them, only whether a key exists and its length
  (`tasks/lessons.md`, `CLAUDE.md` Working Rules).

## 6. Where state lives and how to reset it

Quit the instance you are resetting first. Never reset the user's live app without asking.

| State | Location | Source |
|---|---|---|
| Preferences (layout, theme, sort order, AI backend, CLI extra PATH, GitHub settings, Whisper model, custom AI filters, last folder) | UserDefaults domain `com.markview.MarkView` | bundle id `project.pbxproj`. Every key is declared once in `Packages/MarkViewCore/Sources/MarkViewCore/SettingsKeys.swift` (for example `workspace.lastFolder`); UI state of a window is `@WindowStorage` (`WindowUIState`), not a shared key |
| OpenAI API key (Whisper, embeddings) | the Keychain (`AR-10`) | `WhisperClient.loadAPIKey` / `saveAPIKey` in `MarkView/Models/Dictation/WhisperClient.swift`; `EmbeddingClient` delegates to it |
| Per-folder index (SQLite + FTS5), caches, overlays | `<folder>/.dde/` (`state.db`, `cache/`, `overlays/`), git-ignored (`.gitignore`) | `MarkView/Models/Shared/SemanticDatabase.swift` |
| Index fallback when `.dde/` cannot be created | `~/Library/Application Support/MarkView/Projects/<ProjectPaths.projectCacheIdentifier>/` | `SemanticDatabase.swift` (`AR-39`) |
| Recent files | `~/Library/Application Support/MarkView/recentFiles.json` | `MarkView/Models/Workspace/ProjectContext.swift` |
| Lifecycle events (append-only, shared by all windows) | `~/Library/Application Support/MarkView/lifecycle-events.jsonl` | `MarkView/Models/Lifecycle/LifecycleLog.swift` |
| CLI login helpers | `~/Library/Application Support/MarkView/login-*.command` | `AIAssistants.swift`, `MarkView/Views/Git/GitHubViews.swift` |
| PR X-Ray file copies | `~/Library/Caches/MarkView/pull-requests/<repo hash>/<label>/` | `MarkView/Models/Architecture/ChangeSource.swift` |
| Pasted images | `~/Library/Caches/MarkView/pasted-images/` | `MarkView/Models/Terminal/TerminalSession.swift`, `MarkView/Models/Browser/BrowserElementPick.swift`, `MarkView/Views/Lifecycle/IntakeTextEditor.swift` |
| Temp files | `$TMPDIR/markview-cli/` (empty cwd for CLI runs), `$TMPDIR/insight-export-<uuid>/` (while a ZIP export runs), `$TMPDIR/markview_whisper_<uuid>.wav` | `MarkView/Models/AI/CLICompletion.swift`, `MarkView/Models/Insight/InsightArchiveExport.swift`, `WhisperClient.swift` |
| Legacy sandbox container | `~/Library/Containers/com.markview.MarkView/` (from before the sandbox was turned off); nothing in the repository reads it any more | – |

Resets:

```bash
defaults read com.markview.MarkView                      # inspect first
defaults delete com.markview.MarkView workspace.lastFolder   # stop reopening the last folder
defaults delete com.markview.MarkView                    # all preferences (the OpenAI key is in the Keychain, not here)
rm -rf <folder>/.dde                                     # rebuild that folder's index on next open
rm -rf ~/Library/Caches/MarkView                         # PR copies, pasted images
```

Before deleting `lifecycle-events.jsonl`, keep a copy: it is the only record of lifecycle
history. The `.dde/` layout and settings keys are stored data, so an incompatible change to
them is a major version bump (`CLAUDE.md` Versioning).

## 7. Common failures and fixes

| Symptom | Cause and fix | Source |
|---|---|---|
| Beachball when opening a large folder | Synchronous `Process`/git on the main thread, or pipe read after `waitUntilExit`. Run child processes off the main thread and drain pipes concurrently | `tasks/lessons.md` |
| Child process `terminationHandler` never fires | The `Process` was released. `MarkViewCore.Subprocess` holds it until the handler runs; new call sites use it | `tasks/lessons.md` |
| Codex/Claude "does nothing" | Hard-coded CLI path. Resolve in order: settings override → candidates including every `~/.nvm/versions/node/*/bin` → login shell. Check sign-in with `claude auth status` / `codex login status` | `tasks/lessons.md`, `AIAssistants.swift` |
| Codex run shows an "error" but works | `{"type":"error"}` events can be warnings; only `turn.failed` is fatal | `tasks/lessons.md` |
| Crash (SIGTRAP) at launch after toolbar changes | `@EnvironmentObject` inside `.toolbar`. Pass objects as parameters, and launch the built app to verify | `tasks/lessons.md` |
| Menu item stuck enabled or disabled | Menu state read from an object behind `@FocusedValue`. Use a value-typed `focusedSceneValue` | `tasks/lessons.md` |
| Finder "Open With" opens nothing | Notification sent before the window attached. Queue external requests durably and drain them | `tasks/lessons.md` |
| Blank editor or terminal web view | New file in `Resources/Editor` not copied by the pre-build script | `tasks/lessons.md` |
| "no column named ..." after an upgrade | Column added without a migration. Append a step to `SemanticSchema.migrations` (`SQLiteSchema.addMissingColumns`) | `tasks/lessons.md`, `MarkView/Models/Shared/SemanticSchema.swift` |
| Editor panel will not hide | CSS `display` overrides `[hidden]`. Add `[hidden]{display:none}` (with `!important` for CodeMirror) and check in WebKit | `tasks/lessons.md` |
| Terminal link opens nothing or triggers TUI clicks | OSC 8 links need `linkHandler`; reserve Cmd+click; resolve against the live cwd | `tasks/lessons.md` |
| Dictation keeps the microphone on or writes into the wrong field | Capture a generation token and the originating window | `tasks/lessons.md` |
| Recording lost when switching tabs | Long-lived work owned by `@StateObject` of a transient view. Move it to the model | `tasks/lessons.md` |
| Memory spike while scanning agent logs | Read in 8 MB chunks inside `autoreleasepool`; measure with `/usr/bin/time -l` | `tasks/lessons.md` |
| "0%" / "1%" usage windows vanish | `NSNumber` matches `is Bool`. Use `CFBooleanGetTypeID` | `tasks/lessons.md` |
| `.md` from the PR cache switches the workspace | Files the app places outside the folder must count as part of the workspace (`isFileInCurrentWorkspace`) | `tasks/lessons.md` |
| First launch blocked by Gatekeeper | DMG not notarized. Use "Open Anyway", or release with `NOTARY_PROFILE` | `release.sh`, `README.md` |
| `release.sh` exits with "No Developer ID Application identity found" | No certificate in the keychain. Install one or set `SIGN_IDENTITY` | `release.sh` |

Process lessons that affect operations:
- Never use `git stash` to compare versions. Use `git show HEAD:path > /tmp/...` or a worktree
  (`tasks/lessons.md`).
- Before deleting a range or a whole file, list its top-level declarations
  (`tasks/lessons.md`).

## 8. Release checklist

1. The working tree holds only the intended changes (`git status`). Credentials and `.dde/` are
   not staged (`CLAUDE.md` Working Rules, `.gitignore`).
2. The version is bumped at the right semver level. Both configurations in `MarkView.xcodeproj/project.pbxproj`
   agree (`./bump-version.sh` checks every occurrence); check with
   `grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' MarkView.xcodeproj/project.pbxproj`.
3. If vendored JS changed: run `tools/web-vendor` `npm ci && ./build.sh` and commit the outputs.
4. The Debug build passes and the relevant `tools/tests/*.sh` pass (sections 1 and 3).
5. Build the release artifact **without** installing:
   ```bash
   NOTARY_PROFILE=<profile> ./release.sh    # default profile: markview-notary; NOTARY_PROFILE= builds without notarization
   ```
   Output: `build/MarkView-<version>.dmg` and its SHA-256 (`release.sh`). Optional:
   `SIGN_IDENTITY="Developer ID Application: …"` (`release.sh`).
6. Smoke-test `build/release/MarkView.app` with `open -n`, then stop only that PID (section 2).
7. Merge through the pull request flow in `CLAUDE.md` (Git Workflow). A push to `main` that changes more than documentation runs
   `Build & Release` (it compiles the app and publishes nothing) and `CI` (`.github/workflows/build-release.yml`, `ci.yml`).
8. Publish the signed, notarized DMG with `./release.sh --publish` from a clean checkout of `origin/main`: it tags `v<version>`
   and marks the release Latest. It refuses anything but a clean checkout of `origin/main` and a version that already has a release (`release.sh`, `CLAUDE.md` Completion).
   `.github/workflows/publish-release.yml` makes the same release from CI.
9. Install only when the user asks in that turn. `./release.sh --install` quits the running app (`release.sh`). If the command runs
   inside a MarkView terminal, the quit kills the script before the copy. Build with `./release.sh`, then run the install steps
   (quit, attach the DMG, `ditto` to `/Applications`, open) detached, for example with
   `nohup bash -c '…' >/tmp/mv-install.log 2>&1 &`, and say beforehand that the session will restart.

### Environment variables used by scripts

| Variable | Used in | Effect |
|---|---|---|
| `SIGN_IDENTITY` | `release.sh` | overrides the auto-detected Developer ID identity |
| `NOTARY_PROFILE` | `release.sh` | `notarytool` keychain profile; turns on notarization and stapling |
| `TARGET_BUILD_DIR`, `UNLOCALIZED_RESOURCES_FOLDER_PATH`, `SRCROOT` | pre-build script, `MarkView.xcodeproj/project.pbxproj` | Xcode build settings; destination of the editor copy |
| `HOME` | legacy paths | User home directory |
| `GH_TOKEN` (`secrets.GITHUB_TOKEN`) | `.github/workflows/publish-release.yml` | CI release publishing |
