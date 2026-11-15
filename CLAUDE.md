# MarkView Development Guide

## Project

MarkView is a native macOS 13+ documentation environment built with Swift 5.9,
SwiftUI, AppKit, and WKWebView. The Xcode project has one application target (`MarkView`)
and a local Swift package (`Packages/MarkViewCore`) providing pure domain logic and
shared infrastructure (`Core/`).

The editor used by the app lives in `MarkView/Resources/Editor/`. In particular,
`index.html`, `vendor/js/mv-kit.js`, and `vendor/js/markview-*.js` are the shipping
implementation.

## Repository Map

- `MarkView/App/`: application entry point, window scenes, Finder open handoff (`MarkViewApp.swift`)
- `Packages/MarkViewCore/`: local Swift package linked into `MarkView` (`Subprocess`, `PathSafety`, `AtomicFile`, `SingleFlight`, `RotatingJSONLinesFile`, `MarkViewPaths`, `ContentDigest`, `SettingsRegistry`, `WebHost`, `WeakScriptMessageHandler`) with `swift test` target (`MarkViewCoreTests`)
- `MarkView/Views/`: SwiftUI views and `WKWebView` coordination (`EditorView`, `ContentView`, etc.)
- `MarkView/Models/`: workspace (`WorkspaceManager`, `DocumentScrollSideTable`, `TaskBag`, `PanelLayout`), AI (`AIOperation`, `AssistantProviderRegistry`, `CLICompletion`), indexing (`SemanticDatabase`), storage (`SchemaVersionedStore`, `WindowSessionStorage`), registries (`ToolRegistry`), search, browser control (`BrowserControlServer`), and Git behavior
- `MarkView/Bridge/`: Swift-to-JavaScript bridge (`WebViewBridge`) and PDF export
- `MarkView/Resources/Editor/`: bundled HTML, JavaScript (`mv-kit.js`, `markview-*.js`), CSS, and vendor assets (including `dompurify.min.js` and `turndown.js`)
- `Tests/Fixtures/` and `TestFiles/`: manual and fixture data, plus `tools/tests/` automated test suites (`tools/tests/run.sh` and `tools/tests/manifest.json`)
- `MarkView.xcodeproj`: canonical Xcode project (XcodeGen and `project.yml` have been retired)
- `tools/web-vendor/`: builds the bundled CodeMirror, Cytoscape, ELK, xterm.js, DOMPurify, and Turndown files in
  `Resources/Editor/vendor/js` (`npm ci && ./build.sh`); never load them from a CDN
- `tasks/todo.md`: active work log; `tasks/archive/`: archived task logs; `tasks/lessons.md`: durable debugging lessons

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
- Never call `Process.waitUntilExit()` on the main thread. Use `MarkViewCore.Subprocess` so pipes
  are drained concurrently with waiting and bounded by timeouts and output caps.
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
`tools/tests/manifest.json` (run all suites with `./tools/tests/run.sh --all`,
pure suites with `./tools/tests/run.sh --tier pure`, or a specific suite with
`./tools/tests/run.sh <name>`). Use the relevant fixtures and perform a focused
check for behavior that compilation does not cover.

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
