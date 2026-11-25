---
type: plan
feature: task-aware-agent-execution
title: Task-Aware Agent Execution
issues:
  - id: I-1
    title: Inventory MarkView-initiated agent invocations
    summary: "Trace background CLI and ACP calls, terminal handoffs submitted by MarkView, managed Cockpit steps, MarkView-initiated inter-agent actions, and Remote Work across all registered providers and applicable profiles. Record each entry point, prompt, task type, selected and actual launch profiles, applicable capabilities, and evidence-backed disposition. Exclude manually submitted drafts, including PR-review tasks staged with `submit: false`. Document the rationale for retained behavior and unconfirmed candidates, and link confirmed improvements to first-release work."
    requirements: [REQ-005]
    decisions: [DEC-011, DEC-019]
  - id: I-2
    title: Build terminal prompts for the actual recipient
    summary: Resolve the receiving terminal before building provider-specific instructions for single and batch Fix with AI. Check the other automatically submitted handoffs against the same rule. Verify that the prompt fits the actual terminal profile when normal routing picks a provider different from the configured default, and that fixes are marked as fixing only after successful handoff.
    requirements: [REQ-006]
    decisions: [DEC-019]
  - id: I-3
    title: Enforce launch-profile capabilities and confirm provider substitutions
    summary: Determine which task capabilities are available to the actual launch profile under repository settings and existing delegation, write, and delivery permissions. When an explicitly selected provider lacks a needed capability, explain the limitation and offer a compatible configured provider if available. Send task context to the replacement only after explicit confirmation. If confirmation is declined or no compatible provider exists, proceed with the original provider when feasible and report the blocker otherwise.
    requirements: [REQ-006, REQ-008]
    decisions: [DEC-013]
  - id: I-4
    title: Match direct execution, parallel work, and review to the task
    summary: Apply audit-confirmed strategy changes to eligible workflows. Keep a direct path for straightforward implementation and bug fixes without adding calls solely for orchestration. Use bounded concurrency for independent work, honor prerequisites, and preserve sequential approved Cockpit steps. Evaluate any additional review against the actual artifact and existing verification criteria. Record the workflows changed and the evidence that supports each new default.
    requirements: [REQ-005, REQ-006, REQ-007]
    decisions: [DEC-011, DEC-014, DEC-018]
  - id: I-5
    title: Implement evidence-backed deep research for new documents
    summary: Use the evidence-backed deep workflow by default when creating a research document through either Research entry point, through their shared intake. For a representative broad question, synthesize distinct lines of inquiry with the sources and tools permitted and available to the actual profile. Check key claims against cited source content, distinguish project facts, external facts, inferences, and open assumptions, and preserve usable evidence with explicit gaps when interrupted or when sources are unavailable.
    requirements: [REQ-006, REQ-008]
    decisions: [DEC-012, DEC-013, DEC-015, DEC-020]
  - id: I-6
    title: Extend deep research to existing-document operations
    summary: Apply the evidence-backed deep workflow to Continue / deepen, Retry incomplete part, and Revise With Comment. Keep the work aligned with each action's scope and verify that it uses only sources and tools permitted and available to the actual profile. Preserve usable evidence and identify gaps on interruption or source failure. Prepare a separate baseline comparison for each action so results from new-document research cannot qualify these defaults.
    requirements: [REQ-006, REQ-008]
    decisions: [DEC-013, DEC-015, DEC-020]
  - id: I-7
    title: Establish the baseline and comparison protocol
    summary: Define representative paired tasks, comparable inputs, workflow-specific quality criteria, and material-gain thresholds before comparison. Capture end-to-end duration, call counts, available usage or cost, and quality, recording unavailable measurements and distinguishing process success from result acceptance. Agree on any cost proxy before using it. Include terminal handoffs submitted by MarkView and record live launch-profile checks and unverified capability assumptions.
    requirements: [REQ-009]
    decisions: [DEC-014, DEC-015, DEC-018, DEC-019, DEC-020]
  - id: I-8
    title: Verify candidates and close the first-release gate
    summary: Compare candidates with current behavior and require a material quality gain for any default with increased measured duration or cost. Apply the same gain requirement when comparable cost is unavailable unless an agreed proxy establishes that cost did not increase. Verify all four Research scenarios separately, exercise both creation entry points, and confirm that each uses only permitted and available sources and tools. Refine and retest any Research scenario that fails. Release only after all four pass and every confirmed in-scope improvement is included.
    requirements: [REQ-005, REQ-008, REQ-009]
    decisions: [DEC-011, DEC-012, DEC-014, DEC-015, DEC-018, DEC-019, DEC-020]
updated: 2026-11-25
schema: 1
---

# Implementation plan — Task-Aware Agent Execution

## I-1: Inventory MarkView-initiated agent invocations

Trace background CLI and ACP calls, terminal handoffs submitted by MarkView, managed Cockpit steps, MarkView-initiated inter-agent actions, and Remote Work across all registered providers and applicable profiles. Record each entry point, prompt, task type, selected and actual launch profiles, applicable capabilities, and evidence-backed disposition. Exclude manually submitted drafts, including PR-review tasks staged with `submit: false`. Document the rationale for retained behavior and unconfirmed candidates, and link confirmed improvements to first-release work.

Requirements: REQ-005
Decisions: DEC-011, DEC-019

## I-2: Build terminal prompts for the actual recipient

Resolve the receiving terminal before building provider-specific instructions for single and batch Fix with AI. Check the other automatically submitted handoffs against the same rule. Verify that the prompt fits the actual terminal profile when normal routing picks a provider different from the configured default, and that fixes are marked as fixing only after successful handoff.

Requirements: REQ-006
Decisions: DEC-019

## I-3: Enforce launch-profile capabilities and confirm provider substitutions

Determine which task capabilities are available to the actual launch profile under repository settings and existing delegation, write, and delivery permissions. When an explicitly selected provider lacks a needed capability, explain the limitation and offer a compatible configured provider if available. Send task context to the replacement only after explicit confirmation. If confirmation is declined or no compatible provider exists, proceed with the original provider when feasible and report the blocker otherwise.

Requirements: REQ-006, REQ-008
Decisions: DEC-013

## I-4: Match direct execution, parallel work, and review to the task

Apply audit-confirmed strategy changes to eligible workflows. Keep a direct path for straightforward implementation and bug fixes without adding calls solely for orchestration. Use bounded concurrency for independent work, honor prerequisites, and preserve sequential approved Cockpit steps. Evaluate any additional review against the actual artifact and existing verification criteria. Record the workflows changed and the evidence that supports each new default.

Requirements: REQ-005, REQ-006, REQ-007
Decisions: DEC-011, DEC-014, DEC-018

## I-5: Implement evidence-backed deep research for new documents

Use the evidence-backed deep workflow by default when creating a research document through either Research entry point, through their shared intake. For a representative broad question, synthesize distinct lines of inquiry with the sources and tools permitted and available to the actual profile. Check key claims against cited source content, distinguish project facts, external facts, inferences, and open assumptions, and preserve usable evidence with explicit gaps when interrupted or when sources are unavailable.

Requirements: REQ-006, REQ-008
Decisions: DEC-012, DEC-013, DEC-015, DEC-020

## I-6: Extend deep research to existing-document operations

Apply the evidence-backed deep workflow to Continue / deepen, Retry incomplete part, and Revise With Comment. Keep the work aligned with each action's scope and verify that it uses only sources and tools permitted and available to the actual profile. Preserve usable evidence and identify gaps on interruption or source failure. Prepare a separate baseline comparison for each action so results from new-document research cannot qualify these defaults.

Requirements: REQ-006, REQ-008
Decisions: DEC-013, DEC-015, DEC-020

## I-7: Establish the baseline and comparison protocol

Define representative paired tasks, comparable inputs, workflow-specific quality criteria, and material-gain thresholds before comparison. Capture end-to-end duration, call counts, available usage or cost, and quality, recording unavailable measurements and distinguishing process success from result acceptance. Agree on any cost proxy before using it. Include terminal handoffs submitted by MarkView and record live launch-profile checks and unverified capability assumptions.

Requirements: REQ-009
Decisions: DEC-014, DEC-015, DEC-018, DEC-019, DEC-020

## I-8: Verify candidates and close the first-release gate

Compare candidates with current behavior and require a material quality gain for any default with increased measured duration or cost. Apply the same gain requirement when comparable cost is unavailable unless an agreed proxy establishes that cost did not increase. Verify all four Research scenarios separately, exercise both creation entry points, and confirm that each uses only permitted and available sources and tools. Refine and retest any Research scenario that fails. Release only after all four pass and every confirmed in-scope improvement is included.

Requirements: REQ-005, REQ-008, REQ-009
Decisions: DEC-011, DEC-012, DEC-014, DEC-015, DEC-018, DEC-019, DEC-020
