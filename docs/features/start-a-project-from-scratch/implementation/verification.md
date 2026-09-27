# Verification — Start a Project from Scratch (2.24.0)

Test copy: Debug build with `PRODUCT_BUNDLE_IDENTIFIER=com.markview.MarkView.nptest` (own defaults, drafts and window
sessions), driven through the Accessibility API by PID; real Claude Code for the AI; real GitHub (account t-boris).

| Check | Requirement / decision | Result |
|---|---|---|
| Welcome screen without a folder shows **New Project...**; the idea is accepted | REQ-001 | ✓ |
| The draft is on disk right after Start, before the AI answers | DEC-015 | ✓ |
| Idea → overview (goal, problem, scope), 5–6 requirements, 3 questions (25–30 s) | REQ-002 | ✓ |
| Blocking questions listed; **Confirm Brief** unavailable while one is open, available after answering | DEC-016 | ✓ |
| Answer → DEC-001 + requirements updated; no new question while others are open | REQ-002, DEC-007 | ✓ |
| Questions in the language of the idea with "Document language" | — | ✓ (after the project-mode note) |
| Quit mid-clarification → relaunch → **Resume** continues; blocking question shown first | DEC-015 | ✓ |
| **Discard** removes the draft | DEC-015 | ✓ |
| Folder of the same name created after the screen showed → **Create** stops, the folder is untouched | DEC-009 | ✓ |
| New name → folder with README, `.gitignore`, `docs/features/<slug>/` (brief, DEC, REQ, open Q, SRC, discussion), `git init` on `main`, nothing committed, `.dde/` ignored; draft removed | REQ-004, DEC-005, DEC-006, DEC-018, DEC-023 | ✓ |
| The window opens the project with its overview and the specification in the Issues list | DEC-011, DEC-013 | ✓ |
| GitHub: signed-in account and owners; no visibility chosen → "Choose private or public" | DEC-010, DEC-017 | ✓ |
| Existing repository with history (`t-boris/MarkView`) refused, nothing written | DEC-010 | ✓ |
| Confirmation lists the private repo to create, the 14 files to commit, origin and push, the integration switch | DEC-018, DEC-020 | ✓ |
| Publish: repo created (private), commit, origin (gh's ssh protocol), push, `main...origin/main`, `settings.github.enabled` on | REQ-003, DEC-018 | ✓ |
| Activation step reported the success as a failure (`?? "The window was closed."`) | DEC-020 | fixed, re-run ✓ |
| Later path: File › Publish to GitHub… in the reopened project → "existing private repository created by MarkView", nothing new to commit → **Connected**; still one commit, no second repository, record removed | REQ-003, DEC-019 | ✓ |
| Pure rules: `tools/tests/new-project-tests.sh` | — | ✓ |

After the code review (no data-loss path found; fixed: an "empty repository" only on GitHub's HTTP 409, 404 only on
"HTTP 404"; owner and name locked while a repository MarkView created is not pushed yet, and a failed progress write
stops publishing; `git status -z` for any file name; a vanished partial folder frees the destination; activation checks
the window shows the published folder; a repository appearing between check and publish is not taken as ours; with
existing history, uncommitted files are committed only when chosen; detached HEAD refused), re-run live: Git tab ›
Publish to GitHub… with the integration off and an uncommitted README → "existing private repository", "No new commit"
(checkbox off), "Push main to origin" → **Connected**; README still uncommitted, one commit. Pure checks incl. a
Cyrillic file name and a rename.

Not run live: a failure in the middle of bootstrap followed by Retry in the same folder (covered by code review and the
stage flags), and the gh sign-in path (`needsSignIn`).

The test repository `t-boris/markview-newproject-test` could not be deleted from here (token without `delete_repo`).
