---
type: plan
feature: previews-from-existing-code
title: Previews from Existing Code
issues:
  - id: I-1
    title: Add code-derived prototype creation and persistence
    summary: Add an explicit existing-code reconstruction mode to prototype creation and carry it through generation and saved prototype metadata. Reuse project file and folder selection, with an empty selection meaning the whole project. Identify web interfaces, including Electron browser renderers, as the supported scope. Preserve the existing requirements-driven creation flow and ensure saved code-derived prototypes reopen with their reconstruction context.
    requirements: [REQ-001]
    decisions: [DEC-001]
  - id: I-2
    title: Reconstruct standalone interactive prototypes from web code
    summary: Implement reconstruction planning and generation that use the selected implementation as the reference for layout, styling, navigation and interactions. Produce an interactive standalone HTML/CSS/JavaScript prototype with simulated data that runs without the original application or backend. Keep generated files within prototype storage and verify that generation leaves application source files unchanged. Validate the flow against representative web and Electron renderer fixtures.
    requirements: [REQ-001]
    decisions: [DEC-001]
  - id: I-3
    title: Disclose and preserve reconstruction assumptions and gaps
    summary: Capture unresolved assumptions and known reconstruction gaps during generation, persist them with the prototype, and make them visible in Studio and available in the approval/export context. Distinguish behavior supported by inspected code from simulated or unavailable behavior so reconstruction is never presented as verified where evidence is missing. Verify that these disclosures survive reopening and remain available during subsequent review.
    requirements: [REQ-001, REQ-002]
    decisions: [DEC-001]
  - id: I-4
    title: Support the complete Studio review and export workflow
    summary: Integrate code-derived prototypes with the established Studio workflow, reusing chat, voice, element pointing, screenshots and image attachments. Verify that accepted edits create saved versions, restoration and conversation persistence work after reopening, and approval produces SPEC.md plus the existing implementation ZIP containing the prototype and review history. Confirm that edits and restoration remain confined to prototype files without synchronizing application source code.
    requirements: [REQ-002]
    decisions: [DEC-001]
  - id: I-5
    title: Add durable preview references for connected-agent handoff
    summary: Add a copyable project-local preview reference and connected-agent resolution using the existing prototype tools. The reference must identify a saved prototype, remain usable after Studio is closed and reopened, and let an agent retrieve its version, files, assumptions, review history and SPEC.md when available. Define and document whether the reference follows the latest saved version or identifies a fixed version, and handle missing prototypes or unavailable referenced versions explicitly. Verify handoff without external publication or automatic source changes.
    requirements: [REQ-003]
    decisions: [DEC-001]
updated: 2026-11-03
---

# Implementation plan — Previews from Existing Code

## I-1: Add code-derived prototype creation and persistence

Add an explicit existing-code reconstruction mode to prototype creation and carry it through generation and saved prototype metadata. Reuse project file and folder selection, with an empty selection meaning the whole project. Identify web interfaces, including Electron browser renderers, as the supported scope. Preserve the existing requirements-driven creation flow and ensure saved code-derived prototypes reopen with their reconstruction context.

Requirements: REQ-001
Decisions: DEC-001

## I-2: Reconstruct standalone interactive prototypes from web code

Implement reconstruction planning and generation that use the selected implementation as the reference for layout, styling, navigation and interactions. Produce an interactive standalone HTML/CSS/JavaScript prototype with simulated data that runs without the original application or backend. Keep generated files within prototype storage and verify that generation leaves application source files unchanged. Validate the flow against representative web and Electron renderer fixtures.

Requirements: REQ-001
Decisions: DEC-001

## I-3: Disclose and preserve reconstruction assumptions and gaps

Capture unresolved assumptions and known reconstruction gaps during generation, persist them with the prototype, and make them visible in Studio and available in the approval/export context. Distinguish behavior supported by inspected code from simulated or unavailable behavior so reconstruction is never presented as verified where evidence is missing. Verify that these disclosures survive reopening and remain available during subsequent review.

Requirements: REQ-001, REQ-002
Decisions: DEC-001

## I-4: Support the complete Studio review and export workflow

Integrate code-derived prototypes with the established Studio workflow, reusing chat, voice, element pointing, screenshots and image attachments. Verify that accepted edits create saved versions, restoration and conversation persistence work after reopening, and approval produces SPEC.md plus the existing implementation ZIP containing the prototype and review history. Confirm that edits and restoration remain confined to prototype files without synchronizing application source code.

Requirements: REQ-002
Decisions: DEC-001

## I-5: Add durable preview references for connected-agent handoff

Add a copyable project-local preview reference and connected-agent resolution using the existing prototype tools. The reference must identify a saved prototype, remain usable after Studio is closed and reopened, and let an agent retrieve its version, files, assumptions, review history and SPEC.md when available. Define and document whether the reference follows the latest saved version or identifies a fixed version, and handle missing prototypes or unavailable referenced versions explicitly. Verify handoff without external publication or automatic source changes.

Requirements: REQ-003
Decisions: DEC-001
