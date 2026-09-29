# MarkView Development Guide

## Project

MarkView is a native macOS 13+ documentation environment built with Swift 5.9,
SwiftUI, AppKit, and WKWebView. The Xcode project has one application target and
no Swift package dependencies.

The editor used by the app lives in `MarkView/Resources/Editor/`. In particular,
`index.html` and `vendor/js/markview-*.js` are the shipping implementation.
`EditorWeb/` is a separate, future modular editor and its build output is not
wired into the macOS app. Do not treat an `EditorWeb` build as an app change.

## Repository Map

- `MarkView/App/`: application entry point and lifecycle
- `MarkView/Views/`: SwiftUI views and WKWebView coordination
- `MarkView/Models/`: workspace, AI, indexing, search, and Git behavior
- `MarkView/Bridge/`: Swift-to-JavaScript bridge and PDF export
- `MarkView/Resources/Editor/`: bundled HTML, JavaScript, CSS, and vendor assets
- `Tests/Fixtures/` and `TestFiles/`: manual and fixture data; there is currently
  no XCTest target
- `project.yml`: XcodeGen source of truth for project structure
- `tools/web-vendor/`: builds the bundled CodeMirror, Cytoscape and ELK files in
  `Resources/Editor/vendor/js` (`npm ci && ./build.sh`); never load them from a CDN
- `tasks/todo.md`: active work log; `tasks/lessons.md`: durable debugging lessons

## Working Rules

- Communicate with Boris in Russian. Write all new and modified repository files,
  including code comments and documentation, in English. Preserve existing
  historical records when they are not being rewritten.
- Read the relevant call path before editing and keep changes focused.
- Preserve unrelated working-tree changes and never commit credentials or local
  workspace data.
- Keep `project.yml` and `MarkView.xcodeproj` aligned when target membership or
  build settings change.
- When changing a JavaScript bridge message, inspect and update both the Swift
  handlers in `WebViewBridge.swift`/`EditorView.swift` and the matching editor
  JavaScript.
- Keep UI state mutations on `@MainActor`; move file, database, network, and
  child-process work off the main thread.
- Never call `Process.waitUntilExit()` on the main thread. Drain process pipes
  before or concurrently with waiting so a full pipe cannot deadlock the app.
- For a hang or beachball, collect evidence first with
  `/usr/bin/sample <pid> 3` and inspect thread 0.
- Treat API keys and document contents as sensitive. Do not print credentials,
  request headers, or full user documents to logs.
- Validate file paths, network responses, and bridge payloads at their boundaries.
- Avoid direct edits to minified third-party assets unless intentionally updating
  the bundled dependency.

## Git Workflow

These rules apply to every agent working in this repository (Claude Code, Codex,
and others). Only an explicit instruction from Boris for a specific change
overrides them.

- Never commit to `main` directly. Start each feature, bug fix, or docs change on
  its own branch from an up-to-date `origin/main`: `feat/<slug>`,
  `fix/<bug-id>-<slug>`, or `docs/<slug>`.
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
`CURRENT_PROJECT_VERSION` in `project.yml` and in both build configurations of
`MarkView.xcodeproj`, keeping all of them equal. Changes to docs, `tasks/` or build
scripts alone do not bump the version. Batch several changes committed together
into one bump at the highest applicable level.

## Verification

After Swift or bundled-editor changes, build the app:

```bash
xcodebuild -project MarkView.xcodeproj -scheme MarkView \
  -configuration Debug -derivedDataPath /tmp/MarkViewDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

For changes confined to `EditorWeb/`, with its dependencies installed:

```bash
cd EditorWeb
npm run type-check
npm run build
```

There is no automated test target yet. Pure modules can carry a standalone
swiftc check under `tools/tests/` (e.g. `tools/tests/lifecycle-tests.sh` for the
lifecycle duration rules in `Models/LifecycleAnalytics.swift`). Use the relevant
fixtures and perform a focused manual check for behavior that compilation does
not cover.

## Completion

For every app-changing feature or bug fix, finish the full workflow: verify the
change, merge its PR, then create a local Release build and signed DMG installer
from the merged `origin/main` commit. Use a separate clean worktree when the main
working tree has unrelated changes. Run `./release.sh --publish` there; it produces
`build/release/MarkView.app` and `build/MarkView-<version>.dmg` and publishes the
signed, notarized and stapled DMG as GitHub release `v<version>` (marked Latest; it
refuses anything but a clean checkout of `origin/main` and an unused version).
Notarization uses the `markview-notary` keychain profile (`NOTARY_PROFILE` overrides
it). Wait for the `Build & Release` run of the merge commit to succeed; its unsigned zip
is only the `latest` pre-release. Verify the app version, code signature, and that
`spctl` accepts the DMG as notarized, and report the release URL and local paths with
the merged PR link. A docs-only change still goes through a PR but needs no
app build or DMG.
