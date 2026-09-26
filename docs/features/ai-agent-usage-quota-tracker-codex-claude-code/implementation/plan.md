---
type: plan
feature: ai-agent-usage-quota-tracker-codex-claude-code
title: AI agent usage & quota tracker (Claude Code, Codex)
issues:
  - id: I-1
    title: Usage data model and agent detection
    summary: "Define the core model: an agent with its detection status, visibility and one of four ordered display states (official, user limit, no limit, unavailable). Each agent holds a list of quota windows, and each window has an id or label, percent used, reset time, source (official or estimated) and last-updated time. Built-in agents are detected when their CLI is on PATH or ~/.claude or ~/.codex exists. Detected agents get a hide toggle in settings. The most constrained window is selected by highest percent; ties go to the later reset."
    requirements: [REQ-001, REQ-002, REQ-004]
    decisions: [DEC-012, DEC-009, DEC-001, DEC-003, DEC-015]
    github: 13
  - id: I-2
    title: Local CLI log parser for Claude Code and Codex usage
    summary: Parse local session and log files in ~/.claude and ~/.codex into absolute token usage per agent. Cost is included only where the logs record it (Claude Code). This feeds both the no-limit state and the fallback estimate. Logs that can't be read or parsed must degrade to 'usage unavailable', never to zero. The parser makes no network calls. Recompute on file-system change events, debounced to at most once every 30 s.
    requirements: [REQ-005, REQ-001]
    decisions: [DEC-007, DEC-013, DEC-010, DEC-012]
    github: 14
  - id: I-3
    title: User-configured fallback limit and window computation
    summary: "Add per-agent settings for the fallback limit: a value with a unit (tokens, or USD only if cost is logged), an anchor date/time in the local timezone and a period (presets or custom). Persist them in MarkView settings and allow clearing the limit. Compute the current window [anchor+n*period, anchor+(n+1)*period), with calendar-month clamping. From that, derive the estimated percent used and the next reset, marked as estimates."
    requirements: [REQ-005, REQ-003, REQ-002]
    decisions: [DEC-014, DEC-002, DEC-013, DEC-015]
    github: 15
  - id: I-4
    title: Official limit data client using stored agent credentials
    summary: Read Claude Code and Codex credentials read-only (from a file or the Keychain), re-reading them on each poll. Use them only to request official percent used and reset time for each window from the vendor's own endpoint. Never use the refresh token, and never persist, log or overwrite credentials. On 401/403, a missing token or a denied Keychain prompt, mark official data unavailable, show a hint, and offer a manual retry without automatically re-prompting.
    requirements: [REQ-006, REQ-002, REQ-003]
    decisions: [DEC-005, DEC-011, DEC-002]
    github: 16
  - id: I-5
    title: Refresh scheduler, caching and staleness
    summary: Orchestrate fetching for each agent. Fetch official data at most every 5 minutes while the AI terminal panel is visible, and on panel open if the cached value is older than 5 minutes. Allow manual refresh with a 60 s cooldown. Apply exponential backoff from 5 to 30 min and honour Retry-After. Don't poll while the panel is hidden. Cache values in memory only. Mark values older than 15 minutes as stale. Resolve each agent's state by precedence, falling back to the local estimate.
    requirements: [REQ-002, REQ-001]
    decisions: [DEC-010, DEC-002, DEC-012]
    github: 17
  - id: I-6
    title: Compact indicator in the AI terminal panel
    summary: "Render one indicator per visible agent in the AI terminal panel. It shows the headline window's percent used, time until reset and a short window label, coloured by fixed thresholds: normal below 80%, warning at 80% up to 95%, critical at 95% and above. The no-limit state shows absolute usage and a 'set a limit' hint with no bar. The unavailable state shows 'usage unavailable'. Estimated and stale values are marked visually. There are no notifications."
    requirements: [REQ-004, REQ-001, REQ-003]
    decisions: [DEC-006, DEC-008, DEC-004, DEC-009, DEC-016, DEC-003]
    github: 18
  - id: I-7
    title: Detail popover with windows, pace and limit settings form
    summary: Clicking an indicator opens a popover. It lists every window with percent used, remaining quota (in the limit's unit), time until reset, the official or estimated marker, 'updated N min ago' and a pace line. It also shows absolute consumed tokens or money where available, the credential hint and retry, a refresh button with cooldown, and the fallback-limit settings form.
    requirements: [REQ-004, REQ-002, REQ-003, REQ-005]
    decisions: [DEC-006, DEC-008, DEC-009, DEC-010, DEC-011, DEC-014, DEC-015]
    github: 19
updated: 2026-09-26
epic: 20
---

# Implementation plan — AI agent usage & quota tracker (Codex, Claude Code, etc.)

## I-1: Usage data model and agent detection (#13)

Define the core model: an agent with its detection status, visibility and one of four ordered display states (official, user limit, no limit, unavailable). Each agent holds a list of quota windows, and each window has an id or label, percent used, reset time, source (official or estimated) and last-updated time. Built-in agents are detected when their CLI is on PATH or ~/.claude or ~/.codex exists. Detected agents get a hide toggle in settings. The most constrained window is selected by highest percent; ties go to the later reset.

Requirements: REQ-001, REQ-002, REQ-004
Decisions: DEC-012, DEC-009, DEC-001, DEC-003, DEC-015

## I-2: Local CLI log parser for Claude Code and Codex usage (#14)

Parse local session and log files in ~/.claude and ~/.codex into absolute token usage per agent. Cost is included only where the logs record it (Claude Code). This feeds both the no-limit state and the fallback estimate. Logs that can't be read or parsed must degrade to 'usage unavailable', never to zero. The parser makes no network calls. Recompute on file-system change events, debounced to at most once every 30 s.

Requirements: REQ-005, REQ-001
Decisions: DEC-007, DEC-013, DEC-010, DEC-012

## I-3: User-configured fallback limit and window computation (#15)

Add per-agent settings for the fallback limit: a value with a unit (tokens, or USD only if cost is logged), an anchor date/time in the local timezone and a period (presets or custom). Persist them in MarkView settings and allow clearing the limit. Compute the current window [anchor+n*period, anchor+(n+1)*period), with calendar-month clamping. From that, derive the estimated percent used and the next reset, marked as estimates.

Requirements: REQ-005, REQ-003, REQ-002
Decisions: DEC-014, DEC-002, DEC-013, DEC-015

## I-4: Official limit data client using stored agent credentials (#16)

Read Claude Code and Codex credentials read-only (from a file or the Keychain), re-reading them on each poll. Use them only to request official percent used and reset time for each window from the vendor's own endpoint. Never use the refresh token, and never persist, log or overwrite credentials. On 401/403, a missing token or a denied Keychain prompt, mark official data unavailable, show a hint, and offer a manual retry without automatically re-prompting.

Requirements: REQ-006, REQ-002, REQ-003
Decisions: DEC-005, DEC-011, DEC-002

## I-5: Refresh scheduler, caching and staleness (#17)

Orchestrate fetching for each agent. Fetch official data at most every 5 minutes while the AI terminal panel is visible, and on panel open if the cached value is older than 5 minutes. Allow manual refresh with a 60 s cooldown. Apply exponential backoff from 5 to 30 min and honour Retry-After. Don't poll while the panel is hidden. Cache values in memory only. Mark values older than 15 minutes as stale. Resolve each agent's state by precedence, falling back to the local estimate.

Requirements: REQ-002, REQ-001
Decisions: DEC-010, DEC-002, DEC-012

## I-6: Compact indicator in the AI terminal panel (#18)

Render one indicator per visible agent in the AI terminal panel. It shows the headline window's percent used, time until reset and a short window label, coloured by fixed thresholds: normal below 80%, warning at 80% up to 95%, critical at 95% and above. The no-limit state shows absolute usage and a 'set a limit' hint with no bar. The unavailable state shows 'usage unavailable'. Estimated and stale values are marked visually. There are no notifications.

Requirements: REQ-004, REQ-001, REQ-003
Decisions: DEC-006, DEC-008, DEC-004, DEC-009, DEC-016, DEC-003

## I-7: Detail popover with windows, pace and limit settings form (#19)

Clicking an indicator opens a popover. It lists every window with percent used, remaining quota (in the limit's unit), time until reset, the official or estimated marker, 'updated N min ago' and a pace line. It also shows absolute consumed tokens or money where available, the credential hint and retry, a refresh button with cooldown, and the fallback-limit settings form.

Requirements: REQ-004, REQ-002, REQ-003, REQ-005
Decisions: DEC-006, DEC-008, DEC-009, DEC-010, DEC-011, DEC-014, DEC-015
