---
type: bug
id: BUG-011
title: Implementation agent repeats answered specification questions
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-28
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Пришлите путь к одной затронутой фиче или багу и пример вопроса, который агент задал повторно. Где в документах уже записан ответ?
    why: Это позволит проверить конкретную передачу контекста и отличить пропущенный ответ от противоречия в спецификации.
    status: answered
    answer: "Found in the project records: docs/features/new-research-repository-grounded-analysis Q-001 and Q-004 (same question, answers C and B), lifecycle Q-002/Q-005; see Resolution."
  - id: BQ-2
    text: Какой AI-агент был выбран при повторном вопросе?
    why: Формулировка передаваемого запроса зависит от выбранного агента.
    options:
      - label: Claude Code
        text: Передача через /goal.
      - label: Codex
        text: Передача обычным запросом.
      - label: Другой агент
        text: Укажите название агента.
    status: answered
    answer: Пробовал все
  - id: BQ-3
    text: Пришлите путь к одной затронутой фиче или багу, повторный вопрос агента и файл, где уже был записан ответ.
    why: Это позволит проверить конкретный случай и выяснить, был ли ответ пропущен или сформулирован неоднозначно.
    status: answered
    answer: "Same evidence as BQ-1 (24 handoff transcripts and 13 specs with duplicate question pairs); see Resolution."
issue: "#52"
---

# Implementation agent repeats answered specification questions

## Summary

The implementation handoff does not explicitly require reviewing recorded answers and accepted decisions before asking questions. This is a plausible cause of repeated questions, but a concrete run is needed to confirm the mechanism.

## Steps to reproduce

1. Open a feature whose specification includes an answered question or accepted decision.
2. Click Implement with AI in the Feature panel.
3. Compare the terminal agent’s questions with the recorded answer and decision. The exact affected feature and run have not been supplied.

## Expected

Before asking implementation questions, the agent reviews the relevant feature specification, including answered questions and accepted decisions, and uses those records while implementing.

## Actual

The user reports that implementation agents sometimes repeat questions answered during discovery. The current handoff sends the feature folder path and a short instruction to read it, but does not explicitly direct the agent to check answered questions or accepted decisions before asking. No affected run is available to establish what the agent actually read.

## Environment

MarkView macOS app, Feature panel → Implement with AI. The user tried all available AI agents. The app version and an affected run are unknown.

## Suspected code

- `MarkView/Models/WorkspaceManager.swift` — implementWithAI sends a path-based prompt for both Claude and other backends. Neither prompt names answered questions or accepted decisions; sendToAssistant pastes the prompt into a terminal session.
- `MarkView/Views/FeaturePanelView.swift` — The Feature panel’s Implement with AI button calls implementWithAI with the feature folder.
- `MarkView/Models/FeatureModels.swift` — Questions and decisions have distinct statuses, including answered and accepted, that the handoff could direct the agent to review.

## Likely causes

- The prompt leaves which files in the feature folder to review implicit.
- The prompt invites questions without first requiring a check against recorded answers and accepted decisions.
- Inference: terminal agents may read only part of the feature specification. This has not been confirmed from a run.

## Missing information

- An affected feature path, the repeated question, and the file containing its prior answer are needed to reproduce the reported behavior end to end.
- The app version and terminal transcript for an affected run are unknown.

## Clarifications

**BQ-2** Какой AI-агент был выбран при повторном вопросе?
→ Пробовал все

## Original description

Мне кажется, когда мы посылаем на имплементацию что-то, ну, фичи или баг уже проверенный, например, фичу, он начинает мне задавать вопросы, которые у меня задавал до этого, на которые я уже отвечал. То есть, такое ощущение, как будто он не посылает весь контекст, ну, этой фичи, и из-за этого задает еще вопросы. Проверь, так ли это, если это так, то почини.

## Clarifications (fix)

- Owner (2026-09-27): fix discovery by asking open questions first for every feature; also make the Implement /
  Fix with AI prompts name the binding records and ask for write-back; leave the existing specs with duplicate
  question pairs as they are.

## Resolution (2.26.1)

- Reproduction of the suspected cause (handoff prompt): the old prompt, run headless 3× with Claude Code and 3×
  with Codex on a fixture feature whose answers live only in an answered question, an accepted decision and
  discussion.md, used every recorded answer; one Claude run asked whether the discussion.md rule was binding.
  In 24 real handoff transcripts (MarkView, broker-fabric, vivaa-platform) only 4 questions repeated a recorded
  answer; about 47 were real gaps or contradictions in the spec.
- Root cause: guided discovery asked the intake's questions again. Intake creates Q-001…Q-003 as open; the
  Explore stage shows the newest open question; answering it made `answer(next: true)` generate a new question
  although the others were still open, and the AI often repeated them (they were listed as open in its context).
  The originals came back last, so the owner answered the same question twice, sometimes differently — e.g.
  new-research Q-001/Q-004 (C vs B), Q-002/Q-005 (C vs D), lifecycle Q-002/Q-005; 13 specs have such pairs, and
  their conflicting decisions then surfaced as "repeated" questions from the implementation agent. 2.24.0 had
  fixed this for new projects only (`projectDiscovery && …` in `FeatureAI.answer`).
- Fix: open questions first for every feature — `answer` asks for no new question while another is open, and
  `exploreNext` (Skip, Ask next question) returns without an AI call while one is open. The handoff prompts come
  from `HandoffPrompt`: recorded answers (answered questions, accepted decisions, resolved findings,
  discussion.md; for bugs the answered report questions and `## Clarifications`) are binding and not asked again,
  only gaps and contradictions are asked about, and every new answer is written back. The batch Fix prompt got
  the same bug clause.
- Verified: `tools/tests/handoff-prompt-tests.sh`, `tools/tests/bug-basket-tests.sh`, Debug build. Test copy
  (own bundle ID), real intake with Claude Code: 3 intake questions; answering Q-003 created no question and
  Explore showed Q-002, then Q-001; only after the last one did discovery add Q-004 (a new topic). New prompt,
  headless: 3/3 Claude runs applied every record without asking, asked only the real gap (encoding) and named the
  records checked; after the answer the agent wrote it back (Q-002 answered, DEC-003); a fresh run then applied it
  and asked nothing about it; Codex also followed every record.
- Not changed: the 13 existing specs keep their duplicate question pairs (owner's choice).

