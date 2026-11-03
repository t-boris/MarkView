---
type: bug
id: BUG-046
title: X-Ray / Code fails because a component "needs valid source evidence in one of its paths"
status: fixed
branch: fix/bug-046-xray-evidence
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# X-Ray / Code fails because a component "needs valid source evidence in one of its paths"

## Summary

An X-Ray / Code analysis of the MarkView repository ended with

```
Could not analyze the code: The assistant's diagram was not usable: Application Shell needs
valid source evidence in one of its paths; WebViewBridge needs valid source evidence in one
of its paths; DataFileSchemeHandler needs valid source evidence in one of its paths
```

Every component of the diagram must cite one real `path:line` inside the code it owns.
`validateModel` checked this correctly, but it reported all four distinct ways a citation can be
wrong with one identical sentence. The repair round sends that sentence back to the assistant, so
the model was told that something was wrong without being told what, and it could not converge.
A single analysis costs a 15-minute CLI turn, and the whole result was discarded over line
numbers while the structure of the diagram was sound.

## Steps to Reproduce

1. Open a workspace over a large source repository (the MarkView repository itself).
2. Run X-Ray / Code.
3. Let the assistant answer with a diagram whose components cite lines that do not exist, or
   cite a file the component does not own.

## Expected

The analysis either converges — the repair round receives a precise reason and a usable
example — or it keeps the assistant's structure and repairs the citations itself.

## Actual

Both rounds failed on the same uninformative message and the analysis was lost.

## Environment

- MarkView 5.0.1, macOS 13+
- GitHub Copilot CLI assistant, `timeout = 900` per round, two rounds total

## Cause

`CodeArchitecture.validateModel` rejected a component when `sourceLocation(evidence)` returned
`nil` or when the cited path was outside the component's own `paths`, and emitted the same
string in all cases. The reasons it conflated are: no citation at all, a citation whose path is
not a scanned source file, a line past the end of that file, and a real line in a file owned by
another component. `sourceLocation` also accepted only a bare `path:line`, so a model answering
with the equally natural `path:line-end` or `path:line:column` was failed for a formatting
difference. Nothing in the pipeline could recover a diagram whose only defect was a citation.

The exact citations the failing answer used are not recoverable: a failed architecture answer is
never cached and `AICallLog` records outcomes only. The cause above is read from the validation
code and the three component names in the message, all of which own small, parseable files.

## Resolution

- `citationCandidates` accepts `path:line`, `path:line-end` and `path:line:column`.
- `citationProblem` and `dependencyCitationProblem` give five distinct, actionable reasons, name
  the real file length or the paths the component may use, and append a usable citation taken
  from a real definition line in the component's own code.
- The analysis prompt states the `path:line` format and that a line past the end of a file is
  never valid.
- `groundEvidence` is the last resort after the repair round: it replaces only the citations that
  are unusable with real definition lines from files the component already owns, leaves the
  assistant's structure untouched, and the result is validated again before it is used. It cannot
  rescue a component whose `paths` do not exist.

## Verification

- `tools/tests/code-architecture-tests.sh` — citation formats, each diagnostic message, the
  suggested citation, and grounding behavior. The citation tests fail with 8 failures against the
  pre-fix `CodeArchitecture.swift` and pass with the fix.
- Debug `xcodebuild` of the MarkView scheme.
