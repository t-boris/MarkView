---
type: bug
id: BUG-102
title: UI Studio session suite exceeds its 480 s budget on the GitHub macOS runner
status: done
branch: fix/ui-studio-bug-batch
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-05
provenance: Created by an AI agent through MarkView
---

# UI Studio session suite exceeds its 480 s budget on the GitHub macOS runner

## Summary

tools/tests/ui-studio-session-tests.sh ends with "TIMEOUT: no result after 480 s" on GitHub's macos-latest runner (run 42110424597, job ui-studio-session, 2026-11-05) while it passes in 186-213 s on a developer Mac. The steps that start a real development server and open the page take 36-39 s each on the runner (about 4-5 s locally): "the external server answers before the session opens", "BUG-090 the map is complete although the assistant's inventory failed", "REQ-007 the server MarkView starts is found and opened", "REQ-014 a second session does not map the application again", "Cancel stops mapping". The suite last ran in CI on 2026-11-04 (94 s for the step, ui-studio.yml run 41809398150); ui-studio.yml only runs on pull requests, and work goes straight to main, so nothing ran it since. The lifecycle change touched this suite only in its stubs (31 lines), which cannot slow the real-server steps.

## Steps to reproduce

1. Run the ui-studio-session job on GitHub's macos-latest runner (ui-studio.yml, or run tools/tests/ui-studio-session-tests.sh there).
2. Read the log: each real-server session step takes about 36-39 s.

## Expected

The suite finishes inside its watchdog (480 s) and inside the 12 minute step limit of ui-studio.yml.

## Actual

The watchdog fires after 480 s at the step "The development server's own requests are simulated"; the job fails.

## Environment

GitHub Actions macos-latest runner; passes locally on macOS in about 3 minutes.
