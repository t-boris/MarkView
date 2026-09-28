# Workspace redesign verification

Baseline: MarkView `v2.27.0` at `a8a99c3`. Implementation version: `3.0.0`.

## Automated checks

- The Debug app builds with `xcodebuild` for macOS. Xcode reports an unrelated CoreSimulator plug-in warning on this host; the build exits successfully.
- Every existing `tools/tests/*-tests.sh` script passes. The two clipboard/link harnesses now include the existing `AppFontScale` source required by their standalone compilation.
- `workspace-redesign-tests.sh` passes 23 checks: complete handoff snapshots and revision history, ready-again behavior, external additions/modifications/deletions, durable history after `.dde` removal, linked-path validation, project search scopes and exclusions, search refresh and result limits, and observed-change review.
- `WindowSessionTests.swift` passes 20 checks, including restored workspace area, Work section, and the three column visibility states.
- `git diff --check` passes.

## Running-app checks

- Tested the start screen, Files, Project Map, Work, shared search, handoff versions, and assistant terminal in disposable QA copies of the app and disposable projects. The installed MarkView app and the main working tree were not modified.
- Checked a 900 × 600 point window at 200% interface text and a larger window at 100% in light and dark appearances during the initial redesign. Temporarily enabled the system's Increase Contrast setting, inspected the start screen, Work, and Project Map in the running QA app, and restored the setting to Off. X-Ray showed a local map without an AI request, and its details panel stayed collapsed at the smaller size.
- After the three-column correction, checked a 1200 × 800 point QA window with a Markdown document and an active Claude Code terminal. All three docked columns appeared below the full-width header. Closing and reopening left navigation left the document and terminal session visible. Closing the center left navigation and terminal; closing navigation then gave the terminal the full window width. The last visible column could not be closed. Reopening the center showed the same document beside a terminal at least 500 points wide. Reopening the terminal from a document-only layout and switching the center to Work or Project Map also left the terminal visible and its session intact.
- Rechecked the corrected layout at 900 × 600 points and 200% interface text in a disposable QA build with only a temporary window-size hook. The start screen, document beside the terminal, terminal beside the document after hiding navigation, and terminal alone remained reachable. Narrow terminal chrome used icon controls and a compact scope line; the terminal expanded to the full content width when the other columns closed. The temporary hook was removed from the branch.
- Checked that the editor's secondary actions appear in the More menu, the shared search shows file and content matches with paths, handoff revisions compare old and current text, and the Work change review shows an externally added file with a side-by-side comparison.
- Checked terminal Stop and Restart state changes in the running app. The terminal identifies its unrestricted scope and points to observed file changes. Existing terminal prompts remain available.
- Started a live guided-discovery AI action in a disposable feature folder. The action card showed the scope, selected assistant, output, elapsed time, stage, and Stop. Stopping it retained an incomplete status, and the original action could be started again.

## Verification boundaries

- The full third-party assistant and GitHub action matrix in `ai-action-inventory.md` remains a manual integration gate. This session did not exercise every action against live assistant accounts or a remote test repository. The local checks cover lifecycle state, cancellation controls, and external file-change detection without changing remote state.
