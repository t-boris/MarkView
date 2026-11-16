# MarkView Development Guide

## Project

MarkView is a native macOS 13+ documentation environment built with Swift 5.9,
SwiftUI, AppKit, and WKWebView. The Xcode project has one application target (`MarkView`)
and a local Swift package (`Packages/MarkViewCore`) providing pure domain logic and
shared infrastructure (`Core/`).

The editor used by the app lives in `MarkView/Resources/Editor/`. In particular,
`index.html`, `js/mv-kit.js`, and `js/markview-*.js` are the shipping
implementation.

## Repository Map

- `MarkView/App/`: application entry point and window scenes (`MarkViewApp.swift`); the Finder open handoff is
  `Models/Workspace/FinderOpenRequests.swift`
- `Packages/MarkViewCore/`: local Swift package linked into `MarkView` and tested with `swift test` (`MarkViewCoreTests`). It holds the
  infrastructure the app shares: `Subprocess`, `AtomicFile` and `ProjectPaths` (`CoreFiles.swift`), `AppLog`, `JS.call`, `WebHost`
  (with `WeakScriptMessageHandler`), `PrivateSocket`, `SQLiteSchema`, `TaskBag` (keyed cancellable tasks), `PollingScheduler` (the one
  place that polls), and `Settings`/`SettingsKey`/`Setting`/`SettingsObserver`
- `MarkView/Views/`: SwiftUI views and `WKWebView` coordination in 20 domain subfolders (`AI/`, `Appearance/`, `Architecture/`, `Book/`,
  `Browser/`, `Cockpit/`, `Deployments/`, `Dictation/`, `Discussion/`, `Git/`, `Lifecycle/`, `ProjectOps/`, `Prototype/`, `QA/`,
  `Remote/`, `Research/`, `Shared/`, `Terminal/`, `UIStudio/`, `Workspace/`). `Shared/` holds the small views every feature uses
  (`PanelTabButton`, `WindowStorage`, `ImageAttachmentViews`, `FactRows`, `SmallButton`). `ContentView`, `EditorView` and `ToolTabViews` are in `Workspace/`
- `MarkView/Models/`: 22 domain subfolders (`AI/`, `AgentTools/`, `Appearance/`, `Architecture/`, `Book/`, `Browser/`, `Cockpit/`,
  `Deployments/`, `Dictation/`, `Discussion/`, `Git/`, `Insight/`, `Lifecycle/`, `ProjectOps/`, `Prototype/`, `QA/`, `Remote/`,
  `Research/`, `Shared/`, `Terminal/`, `UIStudio/`, `Workspace/`). No Swift file lives directly in `Models/` or `Views/` (`no-loose-swift` lint).
  The folders are layered, lowest first: `Appearance/`, `Shared/` (infrastructure that names no feature domain: `ProjectProviding`,
  `SchemaVersionedStore`, `FrontMatter`, `FileType`, `SemanticDatabase`, `ProjectChangeMonitor`...), `AI/`, the feature domains, then
  `Workspace/`. A folder names its own layer and the ones below it, never a higher one: no feature domain names `Workspace/`
  (the `domain-cycles` lint counts every back-edge; `tools/lint/domain-dependencies.py` measures it). The window hosts that implement a
  feature's window protocol (`BrowserHost`, `CockpitHost`, `PrototypeStudioHost`, `UIStudioHost`, `FeatureFlowCoordinator`,
  `AITerminalsController`) live in `Workspace/` with the window composition; the protocol stays with the feature.
  A window is built by `WindowComposition` (`Workspace/`): its parts (`TabsController`, `ProjectContext`, `PanelLayout`, `WindowTheme`,
  `TaskBag`, and the lazy coordinators) take what they need at construction, and `WorkspaceManager` is the thin facade that conforms to
  their narrow host protocols
- Registries (one entry per thing, no other list to edit): `ToolRegistry` and `ToolTabsRouter` (tools), `AssistantProviders.list`
  (`Models/AI/Providers/`), `Setting` (settings keys), `BackdropRegistry`, `ThemeCatalog` and `LayoutCatalog` (JSON in `Resources/`),
  `SemanticSchema.migrations` (SQLite), `SchemaVersionedStore` (JSON stores), `AIOperation` (every assistant call)
- `MarkView/Bridge/`: Swift-to-JavaScript bridge: `WebViewBridge`, `TypedWebBridge` (validates every page message against
  `Resources/Editor/js/bridge-contract.json`), `PageMessages.swift` (the payload types), the scheme handlers and PDF export
- `MarkView/Resources/Editor/`: bundled HTML (`index.html`, `terminal.html`, `discussion.html`, `book.html`), first-party JavaScript under `js/` (`mv-kit.js`, `markview-*.js`), and third-party vendor bundles under `vendor/` (`dompurify.min.js`, `turndown.min.js`, etc.). `MarkView/Resources/Themes/` and `Layouts/` hold the theme and layout-preset JSON
- `Tests/Fixtures/` and `TestFiles/`: manual and fixture data. `tools/tests/` holds the automated suites (`run.sh`, `manifest.json`);
  `tools/lint/architecture-lint.sh` holds the structural rules and their allow-lists, and `tools/lint/domain-dependencies.py` measures
  the dependencies between domain folders (`--why A B` names the types of an edge)
- `MarkView.xcodeproj`: canonical Xcode project (XcodeGen and `project.yml` have been retired)
- `tools/web-vendor/`: builds the bundled CodeMirror, Cytoscape, ELK, xterm.js, DOMPurify, and Turndown files in
  `Resources/Editor/vendor/js` (`npm ci && ./build.sh`); never load them from a CDN
- `docs/architecture/`: the architecture docs and the review of 2026-11 (status of each finding); `tasks/todo.md`: active work log;
  `tasks/archive/`: archived task logs; `tasks/lessons.md`: durable debugging lessons

## Working Rules

- Communicate with Boris in Russian. Write all new and modified repository files,
  including code comments and documentation, in English. Preserve existing
  historical records when they are not being rewritten.
- Read the relevant call path before editing and keep changes focused.
- Preserve unrelated working-tree changes and never commit credentials or local
  workspace data.
- Keep `MarkView.xcodeproj` and `Packages/MarkViewCore/Package.swift` aligned when target
  membership or build settings change.
- When changing a JavaScript bridge message, inspect and update both the Swift
  handlers in `WebViewBridge.swift`/`EditorView.swift` and the matching editor
  JavaScript (`mv-kit.js` / `markview-bridge.js`).
- Keep UI state mutations on `@MainActor`; move file, database, network, and
  child-process work off the main thread (`SWIFT_STRICT_CONCURRENCY = targeted` is enabled).
- Start every child process through `MarkViewCore.Subprocess`: `run` (async) or `runBlocking` (a
  thread that owns itself, never the main thread) for one-shot commands, `start` for streaming
  children. The child leads a process group of its own, a timeout or a cancelled task ends the
  whole group (SIGTERM, then SIGKILL), pipes are drained concurrently and output is bounded.
  `Process()` and `waitUntilExit` outside `Subprocess` are 0 in `MarkView/` and the Core package
  (`tools/tests/no-process-outside-subprocess-lint.sh`). Two starts are outside it: the PTY
  terminals (`TerminalSession`, `forkpty`) and the UI Studio dev server (`StudioDevServer`, its
  own `posix_spawn`; it ends the whole group when its shell exits, which `Subprocess` does not
  do for a command that ended by itself); only the dev server is a candidate for a later step.
- For a hang or beachball, collect evidence first with
  `/usr/bin/sample <pid> 3` and inspect thread 0.
- Treat API keys and document contents as sensitive. Do not print credentials,
  request headers, or full user documents to logs.
- Validate file paths, network responses, and bridge payloads at their boundaries.
- Avoid direct edits to minified third-party assets unless intentionally updating
  the bundled dependency.

### Architecture & Refactoring Rules

1. **A finding is done when the old thing is gone.** Acceptance is a count that must reach zero
   or a stated number (e.g., `Process()` outside `Subprocess` = 0; `CLICompletion.run` outside
   `AIOperation` = 0; lists to edit for a new tool = 1).
2. **No abstraction without a first real caller in the same pull request,** and the code it
   replaces deleted in that pull request.
3. **One finding (or one extraction step) per pull request.** No multi-phase grab-bag pull requests.
4. **Tests check behavior of the app's path,** never the presence of text. A structural rule
   (e.g., no `Process()` outside Core) is a lint script with an explicit name, not a feature test.
5. **Status follows evidence.** "Done" is written by whoever ran the count, with the count.
6. **`verified` stays the owner's status** (as the feature workflow specifies).

## How to Add

Each line is the number of places to edit; a new Swift file also needs its entries in `MarkView.xcodeproj` (the
`target-membership` lint checks it), and a JSON file in `Resources/Themes` or `Resources/Layouts` needs none (folder references).

- **A tool** (a tab the window can open): 2. A `ToolID` and its `ToolDescriptor` in `ToolRegistry.shared`
  (`Models/Workspace/ToolRegistry.swift`), and its view in `ToolTabViews.builders` (`Views/Workspace/ToolTabViews.swift`). Only a tool
  that needs window wiring adds a case to `ToolTabsRouter.opener(for:)`.
- **An assistant** (a CLI or ACP provider): 2. A provider file in `Models/AI/Providers/` and one line in `AssistantProviders.list`
  (`AssistantProviderList.swift`). A literal `.claude`/`.codex`/... outside that folder fails the `assistant-switch` lint.
- **A theme**: 1. A JSON file in `Resources/Themes/` (`ThemeCatalog`; a person's own themes are JSON in Application Support).
- **A layout preset**: 1. A JSON file in `Resources/Layouts/`, ordered by file name, so by its `NN-` prefix (`LayoutCatalog`).
- **A welcome backdrop**: 1. A class conforming to `BackdropRegistration` and `BackdropDrawing` in `Views/Appearance/*BackdropLayers.swift`.
- **A settings key**: 1. An entry in `Setting` (`Packages/MarkViewCore/.../SettingsKeys.swift`), read through `Settings`,
  `@AppStorage(key)` or `@WindowStorage(key)`. A name never changes once shipped (`settings-key-table-tests` pins them); a literal key
  or a direct `UserDefaults` call fails the `settings-literal` lint. Per-window UI state uses `@WindowStorage`, never `@AppStorage`.
- **A bridge message**: 4. Its entry in `Resources/Editor/js/bridge-contract.json`, its payload type in `Bridge/PageMessages.swift`, its
  `messages.on` handler in `Bridge/WebViewBridge.swift`, and the page's `mvBridge.send(...)` call. A page never posts through
  `messageHandlers` itself (`bridge-no-bypass` lint), and `bridge-contract-tests.sh` runs a sample of every message through the types.
- **A SQLite migration**: 1. A new `SQLiteMigration` at the end of `SemanticSchema.migrations` (`Models/Shared/SemanticSchema.swift`);
  a released step is never edited.
- **A JSON store**: 1. Use `SchemaVersionedStore<T>` (`Models/Shared/`); it separates missing, corrupted and newer-schema files.
  Writes go through `AtomicFile`; paths under `.dde/` come from `ProjectPaths`.
- **A child process**: `MarkViewCore.Subprocess` (see Working Rules). **An assistant call**: `AIOperation`. **A log line**: `AppLog`.

## Git Workflow

These rules apply to every agent working in this repository (Claude Code, Codex,
and others). Only an explicit instruction from Boris for a specific change
overrides them.

- Documentation-only changes (README, `docs/`, `tasks/`, presentations, bug and feature
  records) are committed and pushed straight to `main`, with no branch or pull request
  (Boris, 2026-11-03). Pull from `origin/main` first, stage only your own files, and
  never use `--force`.
- Never commit to `main` directly for anything else. Start each feature or bug fix on
  its own branch from an up-to-date `origin/main`: `feat/<slug>` or
  `fix/<bug-id>-<slug>`.
- When the work is committed, the version is bumped, and the build passes, push
  the branch and open a pull request into `main` with `gh pr create`. Use one
  pull request per feature or bug. Describe the changes, the version, and a test
  plan.
- After local verification and required PR checks pass, merge the pull request
  (`gh pr merge --merge --delete-branch`) as part of completing the task. Do not
  wait for a separate merge request unless Boris asked to leave the PR open.
  Never run a local `git merge` into `main` and never push to `main` directly.
- Work is not in `main` until its pull request is merged. When you report a
  feature or bug as finished, include the pull request link and say whether it
  is merged.
- Several agent sessions may share this working tree. Do not switch branches or
  stash over someone else's uncommitted changes. Use `git worktree add` for a
  separate branch instead.

## Versioning

Every change to the app bumps the version before it is committed, using semantic
versioning (the app started at 1.0.0):

- `patch` — bug fixes and small corrections with no new behavior
- `minor` — new features or noticeable improvements; backward compatible
- `major` — removed or reworked user-facing features, or incompatible changes to
  stored data (`.dde/` layout, settings keys)

Run `./bump-version.sh patch|minor|major`. It updates `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in both build configurations of `MarkView.xcodeproj`,
keeping all of them equal. Changes to docs, `tasks/` or build scripts alone do
not bump the version. Batch several changes committed together into one bump at
the highest applicable level.

## Verification

After Swift or bundled-editor changes, build the app and run the test suites:

```bash
xcodebuild -project MarkView.xcodeproj -scheme MarkView \
  -configuration Debug -derivedDataPath /tmp/MarkViewDerivedData \
  CODE_SIGNING_ALLOWED=NO build

swift test --package-path Packages/MarkViewCore
./tools/tests/run.sh --tier pure
./tools/tests/run.sh --changed
```

Standalone verification suites live under `tools/tests/` and are cataloged in
`tools/tests/manifest.json`. Each suite has a tier: `pure` (no app, no window), `gui` (builds or drives the app) and `live`
(needs a real assistant or network). Run all suites with `./tools/tests/run.sh --all`, one tier with `--tier pure|gui|live`,
the suites of the files you changed with `--changed [ref]` (it exits 3 when files changed but no suite covers them), or one
suite with `./tools/tests/run.sh <name>`; `--list` and `--dry-run` show what would run. Use the relevant fixtures and perform
a focused check for behavior that compilation does not cover.

The structural rules are `./tools/lint/architecture-lint.sh` (CI runs it in the pure job): zero-count rules such as
`process` and `clicompletion`, and ratchets whose allow-lists in `tools/lint/*.txt` may only shrink (`--tighten` rewrites them to
today's counts and refuses a rise). A new site is fixed, not added to a list.

## Completion

For every app-changing feature or bug fix, finish the full workflow: verify the
change, merge its PR, then create a local Release build and signed DMG installer
from the merged `origin/main` commit. Use a separate clean worktree when the main
working tree has unrelated changes. Run `./release.sh --publish` there; it produces
`build/release/MarkView.app` and `build/MarkView-<version>.dmg` and publishes the
signed, notarized and stapled DMG as GitHub release `v<version>` (marked Latest; it
refuses anything but a clean checkout of `origin/main` and an unused version).
Notarization uses the `markview-notary` keychain profile (`NOTARY_PROFILE` overrides
it). Wait for the `Build & Release` run of the merge commit to succeed (it only compiles
the app and publishes nothing: the signed DMG is the only installer on GitHub). Verify the app version, code signature, and that
`spctl` accepts the DMG as notarized, and report the release URL and local paths with
the merged PR link. A docs-only change is committed directly to `main` (see Git
Workflow) and needs no app build or DMG.
