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

Per [DEC-011](./decisions/DEC-011.md), Steps A–D of `architecture-review-2026-11-followup.md` (documentation & rules alignment, CI/test restoration, remaining web/Swift security fixes, `MarkViewCore` linking, unused-code cleanup, and initial real callers for `Subprocess`, `ToolRegistry`, `DocumentScrollSideTable`, `AIOperation`, and `SchemaVersionedStore`) are implemented in `architecture-review-2026-11`. Remaining Step E multi-caller migrations are deferred to dedicated per-finding PRs under Section 6 Rule 3, while feature `status` stays `implementing` until the owner sets `verified` (Rule 6).
