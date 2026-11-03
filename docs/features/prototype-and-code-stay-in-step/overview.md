---
type: feature
id: prototype-and-code-stay-in-step
title: Prototype and code stay in step
status: ready
owner: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView from Boris's request in the Prototype Studio discussion, 2026-11-03
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
---

# Prototype and code stay in step

## Idea

Problem: a prototype reconstructed from existing code drifts away from the code, and the reviewer has no precise way to work with it. (1) A change request can only name one clicked element; a whole screen, a component or the whole prototype cannot be the target. (2) "Sync from code" clears site/ and runs the full build again even when one source file changed, so it is slow and expensive on a large app, and it drops Studio edits from the live version (DEC-005 of previews-from-existing-code). (3) Changes made in Studio have no path into the application code: an agent given the prototype reference cannot tell what changed in the prototype. Who: a reviewer using Prototype Studio together with AI agents on a web project. Scope IN: choosing the target of a change request (whole prototype, screen, component, element); a sync baseline remembered with every saved version; incremental code to prototype sync that rebuilds only the units whose sources changed and keeps everything else, including Studio edits; a hand-off that gives an agent the prototype changes since the baseline so the agent changes the code on a branch and opens a pull request; agents reading those changes through the prototype reference. OUT: Studio writing application source code itself; automatic bidirectional synchronization; replacing the reconstruction with the running application. Builds on previews-from-existing-code (REQ-006 sync, REQ-007 component markers, DEC-005).

## Problem

## Scope
