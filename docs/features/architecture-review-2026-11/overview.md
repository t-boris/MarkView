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

Per [DEC-011](./decisions/DEC-011.md), Steps A–D of `architecture-review-2026-11-followup.md` (documentation and rules alignment, CI and test restoration, web and Swift security fixes, linking `Packages/MarkViewCore`, unused-code cleanup, and one first real caller for each of `Subprocess`, `ToolRegistry`, `DocumentScrollSideTable`, `AIOperation` and `SchemaVersionedStore`) were delivered in 6.26.1 and 6.26.2. The remaining multi-caller migrations (Step E) were carried out on `feat/architecture-review-finish`; their measured result is below and in `architecture-review-2026-11-followup.md` section 13. By an owner decision of 2026-11-15 that work ships as one pull request with one commit per finding; this waives the "separate per-finding pull requests" of DEC-011 for it only. The feature `status` stays `implementing` until the owner sets `verified` (Rule 6).

## Status

Counts of 6.26.2 (`6facd9f`) come from sections 10.1 and 12.1 of the follow-up document; the counts dated 2026-11-15 come from section 13 of it. A finding is done only when its count reaches the target (Rule 1).

Delivered: `Packages/MarkViewCore` is linked and the duplicate `MarkView/Core/` is gone; `MarkView/Models/` (21 folders) and `MarkView/Views/` (19 folders) have no loose files; first-party scripts live in `Resources/Editor/js/`; CI runs the whole pure tier. The folder move changed no dependency.

Reached their counts: AR-25 (`Process()` outside `Subprocess` 17 -> 0), AR-26 (`CLICompletion.run` outside `AIOperation` 55 -> 0), AR-35 (assistant switches 0), AR-28 (typed bridge, string `case` 29 -> 0), AR-37 and AR-38 (`SemanticDatabase` is an `actor` with a migration list), AR-30, AR-46, and the Swift half of AR-27 (`WKWebViewConfiguration(` 10 -> 0).

Not at target on 2026-11-15 (measured at the merge tip `ac3001ba` of `feat/architecture-review-finish`; base 6.26.2):

- AR-14, AR-17, AR-19: `WorkspaceManager.swift` is 730 lines (5,747 at 6.26.2; target under 1,000: met) but 56 views still take the whole manager (62; target 0); 33 closure hooks and 4 back-references remain behind ratchets; unowned tasks 263 in 70 files (391 in 87).
- AR-31: places to edit for a new tool 2 (about 7 at 6.26.2; target 1).
- AR-20 and AR-21: 22 `Models/` domain pairs are still in cycles (28 mutual pairs at 6.26.2); no layer rule exists, only a ratchet.
- AR-04, AR-24, AR-27 and AR-29: 27 `evaluateJavaScript` sites (57), 35 `.write(to:` sites (112), 80 `innerHTML =` sinks and 63 `<script>` tags with no module system.
- AR-36, AR-39, AR-40, AR-42, AR-43: partial; the warning count of AR-43 and the main-thread cost of AR-42 were not measured in this pass.
- FU-20 to FU-29 (follow-up section 13): FU-25 stays open (cached Insight HTML keeps `'unsafe-inline'`); FU-10 was never run live.
