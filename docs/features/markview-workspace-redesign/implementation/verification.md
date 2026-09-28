# Workspace redesign verification

Baseline: MarkView `v2.27.0` at `a8a99c3`. Implementation version: `3.0.0`.

## Automated checks

- The Debug app builds with `xcodebuild` for macOS. Xcode reports an unrelated CoreSimulator plug-in warning on this host; the build exits successfully.
- Every existing `tools/tests/*-tests.sh` script passes. The two clipboard/link harnesses now include the existing `AppFontScale` source required by their standalone compilation.
- `workspace-redesign-tests.sh` passes 23 checks: complete handoff snapshots and revision history, ready-again behavior, external additions/modifications/deletions, durable history after `.dde` removal, linked-path validation, project search scopes and exclusions, search refresh and result limits, and observed-change review.
- `WindowSessionTests.swift` passes 19 checks, including restored workspace area and Work section.
- `git diff --check` passes.

## Running-app checks

- Tested the start screen, Files, Project Map, Work, shared search, handoff versions, and assistant terminal in disposable QA copies of the app and disposable projects. The installed MarkView app and the main working tree were not modified.
- Checked a 900 × 600 point window at 200% interface text and a larger window at 100% in light and dark appearances. Primary content remained reachable through compact navigation/context controls. X-Ray showed a local map without an AI request, and its details panel stayed collapsed at the smaller size.
- Checked that the editor's secondary actions appear in the More menu, the shared search shows file and content matches with paths, handoff revisions compare old and current text, and the Work change review shows an externally added file with a side-by-side comparison.
- Checked terminal Stop and Restart state changes in the running app. The terminal identifies its unrestricted scope and points to observed file changes. Existing terminal prompts remain available.

## Verification boundaries

- Increased-contrast appearance was reviewed through color-independent labels and accessibility labels in code, but the host's system-wide increased-contrast setting was not changed for a visual run.
- The full third-party assistant and GitHub action matrix in `ai-action-inventory.md` remains a manual integration gate. This session did not exercise every action against live assistant accounts or a remote test repository. The local checks cover lifecycle state, cancellation controls, and external file-change detection without changing remote state.
