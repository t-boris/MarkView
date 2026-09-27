# Verification — 2.23.0

Verified on 2026-09-27 in an isolated app copy with its own preferences and a disposable repository. The user's workspace was not used for injected AI failures.

| Requirement | Evidence |
| --- | --- |
| REQ-001 | Native intake and document context-menu submissions show Answer first above details. Submission restores hidden Details. Long responses have an independent scroll area. |
| REQ-002 | Real readonly Claude response explained meaning, motivation, mechanism and origin with code, DEC, component and introducing-commit citations. Prompt includes discovered files' exact git blame/log ranges and bounded PR bodies, and explicit unavailable-history notes. Parser rejects location-only/incomplete answers; absent origin is explicit. |
| REQ-003 | Native code, document, logical component, deployment and local commit navigation verified. A PR citation opened the existing GitHub PR #34 in Chrome. All cited file/node ratings are retained across X-Ray scans; readable unindexed source files receive transient nodes. |
| REQ-004 | No research directory before Save in the initial fixture. Save created a new numbered RES with the complete question, sections and sources. File citation links resolve to the workspace with line ranges. Eight simultaneous saves reserve different numeric IDs; existing files remain unchanged. |
| REQ-005 | Injected empty and failed responses displayed a reason and Retry; Retry repeated the exact question and kept computed evidence. Timeout uses the same explicit error path. Closing clears the temporary filter and answer. |

User-authorized additions:

- **Dictate:** labelled, high-contrast button visible in both Understand and New Research, using the existing key-gated dictation controller. Cursor insertion regression checks pass. No microphone recording or live Whisper call was made for verification.
- **Image paste:** Preview → Select All → Copy → ⌘V added a blue PNG thumbnail in both forms. Removal, repeat paste, ordinary text paste, selection replacement and Undo were verified. A real Claude answer correctly described the attached blue square. Question images are supplied from `.dde/understanding/` to the readonly agent; Retry reuses them. Explicit Save copied the image into research assets and rendered it in the document.
- **Folder Research:** right-clicking `docs` opened New Research with that folder selected. The submitted primary target list included `docs/DEC-001.md`, `docs/nested/NOTES.md`, and existing research documents. The generated fixture report recorded the expanded list and copied pasted-image attachment. The picker also accepts folders and individual documents.

Automated checks:

- `tools/tests/understanding-answer-tests.sh`: 30 checks for typed evidence, path/URL boundaries, full explicit saves, attachments and concurrent ID allocation.
- `tools/tests/intake-clipboard-tests.sh`: PNG/TIFF, unique filenames, Finder URLs, text/HTML fallback and write errors.
- Existing research document checks and updated dictation insertion checks. The old dictation fixture expected direct view edits predating BUG-003; it now verifies binding edits, cursor ranges, Unicode, window isolation and stale-selection fallback.
- `node --check MarkView/Resources/Editor/vendor/js/markview-architecture.js` and `git diff --check`.
- Debug build and Developer ID signed Release build; signature verified with `codesign --verify --deep --strict`.

The native navigation/error/folder checks used deterministic CLI responses. Meaning/origin and image interpretation were additionally tested with the real Claude CLI. Other assistant backends and a full timeout-duration wait were not exercised.
