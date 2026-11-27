---
type: bug
id: BUG-135
title: "X-Ray code analysis takes 5-10 minutes: every analysis asks twice, the answer lists hundreds of files, Codex subagents re-read the code"
status: in-review
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
related: BUG-046
schema: 1
---

# X-Ray code analysis takes 5-10 minutes: every analysis asks twice, the answer lists hundreds of files, Codex subagents re-read the code

## Summary

Boris (2026-11-27): "code in X-Ray became much slower". Evidence from ai-calls.jsonl for the MarkView project (Codex gpt-6-luna). (1) An analysis usually needs a second full call: 31 of 45 analyses today, 55-75% every day this week. `CodeArchitecture.validateModel` rejects the whole answer for one unknown path among hundreds or one wrong citation line, and the repair rewrites the whole answer (12-16k output tokens again). The local grounding fallback (`groundEvidence`) runs only after the second rejection. (2) The answer size swings with the model: 35-39 components and 87-151 paths (22-26 KB, ~100 s) or 75-87 components and 485-640 paths (52-74 KB, 200-320 s); the latest analyses were the large kind, about 9.5 minutes for call + repair. Duration follows the output tokens (about 19 s per 1000). (3) Since 7.16.0 a Codex one-shot call with a readable folder starts subagents: the first 7.21.0 analysis read 1.3M input tokens (60-300k before) at about the same speed. The language (about 20-28% Cyrillic) did not change. Boris chose on 2026-11-27: fix locally first, components own directories instead of file lists, and no Codex subagents in X-Ray's code calls.

## Steps to reproduce

1. Open the MarkView project with Codex as the X-Ray assistant
2. Change a source file so the automatic code analysis runs (Code view: Reading the code architecture)
3. Read the code-architecture rows in ~/Library/Application Support/MarkView/ai-calls.jsonl: two consecutive calls per analysis, 12-16k output tokens each

## Expected

One call per analysis in the usual case; problems a local fix can solve (unknown paths, citation lines) never cost a second call; the answer names directories instead of hundreds of files; no subagents re-read the code.

## Actual

Two full calls per analysis, 4-10 minutes in all; up to 640 paths in one answer; 1.3M input tokens in the first 7.21.0 call.

## Environment

MarkView 7.7.1 and 7.21.0, Codex CLI gpt-6-luna medium, MarkView repository (hundreds of source files), 2026-11-27
