---
type: feature
id: architecture-review-2026-11
title: Architecture Review 2026-11
status: implementing
owner: Boris Tsekinovsky
created: 2026-11-15
provenance: Created by an AI agent through MarkView from docs/architecture/architecture-review-2026-11.md
understanding:
  Problem: unknown
  Target Users: unknown
  Primary Workflow: unknown
  Permissions: unknown
  Failure Scenarios: unknown
  Data Model: unknown
  Notifications: unknown
  Security: unknown
  Analytics: unknown
  Dependencies: unknown
  Acceptance Criteria: unknown
issues: [414]
---

# Architecture Review 2026-11

## Idea

Implement all findings (AR-01..AR-49) and roadmap phases (Phase 0 through Phase 7 plus Continuous items) specified in docs/architecture/architecture-review-2026-11.md, applying the owner's binding decisions from Section 13.

## Problem

Following v6.26.0, [architecture-review-2026-11-followup.md](../../../architecture/architecture-review-2026-11-followup.md) identified follow-up defects (`FU-01`..`FU-13`), unlinked `Packages/MarkViewCore`, un-migrated security/storage/AI callers, and outdated documentation/test coverage.

## Scope

Per [DEC-011](./decisions/DEC-011.md), Steps A–D of `architecture-review-2026-11-followup.md` (documentation and rules alignment, CI and test restoration, web and Swift security fixes, linking `Packages/MarkViewCore`, unused-code cleanup, and one first real caller for each of `Subprocess`, `ToolRegistry`, `DocumentScrollSideTable`, `AIOperation` and `SchemaVersionedStore`) were delivered in 6.26.1 and 6.26.2. The remaining multi-caller migrations (Step E) are **in progress (feat/architecture-review-finish)**. By an owner decision of 2026-11-15 that work ships as one pull request with one commit per finding; this waives the "separate per-finding pull requests" of DEC-011 for it only. The feature `status` stays `implementing` until the owner sets `verified` (Rule 6).

## Status

Counts as of 6.26.2 (`6facd9f`), from sections 10.1 and 12.1 of the follow-up document; a finding is done only when its count reaches the target (Rule 1).

Delivered: `Packages/MarkViewCore` is linked and the duplicate `MarkView/Core/` is gone; `MarkView/Models/` (21 folders) and `MarkView/Views/` (19 folders) have no loose files; first-party scripts live in `Resources/Editor/js/`; CI runs the whole pure tier. The folder move changed no dependency.

Not delivered, all in progress (feat/architecture-review-finish):

- AR-25: 17 `Process()` creations in 15 files outside `Subprocess` (target 0); `Subprocess.run` has 1 caller (`InsightArchiveExporter`). FU-22: the process-group kill does not run.
- AR-26: 55 `CLICompletion.run` calls in 28 files outside `AIOperation` (target 0); `AIOperation` has 1 call site (`ArchitectureStore.xrayCall`).
- AR-36 and AR-39: `SchemaVersionedStore` has 1 user (`WindowSessionStorage`); 23 files hand-roll JSON stores.
- AR-14, AR-17, AR-19: `WorkspaceManager.swift` is 5747 lines (target under 1000) and 62 views take the whole manager (target 0). The Phase 4 coordinators were deleted because nothing called them, so AR-14 steps 2–11, AR-17 and AR-19 have no code yet.
- AR-37 and AR-38: `SemanticDatabase` is still `@MainActor`; delete-the-database-on-mismatch remains.
- AR-28 and AR-29: no typed bridge; three first-party scripts are over 2800 lines (3628, 2998, 2845).
- AR-20: folders only; no layer or dependency boundary exists (28 mutual pairs between `Models/` folders).
- AR-31: `ToolRegistry` drives only the primary toolbar buttons and the sentinel tab URLs; about 7 lists must still be edited for a new tool (target 1).
- FU-20 to FU-29 (follow-up section 12.2), among them FU-20: Mermaid diagrams lose their stylesheet in `mvKit.sanitizeMermaidSvg`.
