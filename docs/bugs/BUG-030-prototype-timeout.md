---
type: bug
id: BUG-030
title: Prototype generation is stopped by fixed stage deadlines
status: fixed
branch: fix/bug-030-prototype-timeout
severity: high
reporter: Boris Tsekinovsky
created: 2026-10-29
---

# Prototype generation is stopped by fixed stage deadlines

## Cause

Boris reported a prototype failing after about 20 minutes with Copilot on another computer.
PrototypeAI imposed per-stage wall-clock limits: 20 minutes for each foundation part, 15 for a
screen, 30 for revisions, 25 for the specification and 40 for planning. CLICompletion forwarded
these limits to the Copilot ACP timer just as it did for other providers. Productive work could
be terminated solely because enough time had passed.

The failing computer's logs were not available locally. The fixed 1200-second foundation limit
was confirmed directly in the source; this is not a claim to have inspected the remote failure log.

## Resolution

CLICompletion.Request accepts an optional wall-clock deadline. Its default remains 180 seconds;
all existing explicitly bounded callers keep their limits. PrototypeAI selects no deadline for
planning, both foundations, screens, review changes, preview repair and specification generation.
The studio's existing Stop action, task cancellation, CLI exits and provider errors still end a run.
File validation, read-only tools and staged result saving are unchanged.

Both the Copilot/Cline ACP transport and the native CLI transport honor the optional deadline.
No provider flags, selected models, credentials or global settings are changed. Removing MarkView's
deadline does not suppress errors returned by the provider itself.

## Verification

- A real signed-in Copilot CLI 1.0.95 completed a structured ACP request with no MarkView deadline.
  This is a short transport check, not a claim of waiting through a 20-minute real generation.
- A complete prototype fixture builds a saved screen, applies a revision and writes a specification.
  Its provider boundary rejects any stage that accidentally reintroduces a wall-clock limit.
- Real completion transports with delayed fixture processes cover unbounded completion, explicit
  deadlines, Stop, provider errors and process cleanup for Copilot ACP and native CLI execution.
- Existing prototype file, image, path and save checks remain in the focused CI workflow.

Run `bash tools/tests/prototype-deadline-tests.sh` and
`bash tools/tests/cli-completion-timeout-tests.sh`. The optional real Copilot check is
`MARKVIEW_COMPLETION_LIVE_COPILOT=/path/to/copilot bash tools/tests/cli-completion-timeout-tests.sh`.
It uses the existing CLI sign-in, a temporary folder and a minimal text-only prompt.
