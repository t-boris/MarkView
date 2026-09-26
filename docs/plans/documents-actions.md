# documents-actions

# DDE Feature Discovery, Review & Requirements Workspace

## 1\. Overview

The goal of this feature is to turn the DDE (Document-Driven Environment) into a workspace where ideas, research, discussions, decisions, and requirements can progressively evolve into implementation-ready specifications.

The DDE should not behave primarily as an IDE or as an AI chat application.

Its primary responsibility is to help users answer:

> What exactly are we building, why are we building it, what decisions have been made, what is still unknown, and is the specification ready for implementation?

The general workflow is:

```text
Idea
  ↓
Explore
  ↓
Research / Ingestion
  ↓
Specification
  ↓
Review
  ↓
Questions / Findings / Conflicts
  ↓
Resolve
  ↓
Decisions
  ↓
Requirements
  ↓
Implementation Plan
  ↓
GitHub Issues
  ↓
Code
```

The Markdown documentation remains the source of truth.

The DDE adds a semantic and AI-assisted layer on top of Markdown.

* * *

# 2\. Core Principles

## 2.1 Documentation First

Documentation is not generated after implementation.

Documentation drives implementation.

The expected lifecycle is:

```text
Intent → Understanding → Decisions → Requirements → Implementation
```

rather than:

```text
Implementation → Documentation
```

* * *

## 2.2 Markdown as Source of Truth

All important information should ultimately be represented in portable Markdown files.

The system may maintain indexes, embeddings, graphs, caches, databases, or other derived data internally, but the authoritative project information should remain human-readable and Git-compatible.

Example:

```text
/features/whatsapp-mirroring/

    overview.md
    requirements.md
    research.md

    decisions/
        DEC-001.md
        DEC-002.md

    questions/
        Q-001.md

    diagrams/

    references/
```

* * *

## 2.3 AI as a Facilitator

AI should not simply generate documents.

Its role is to:

-   understand user intent;
-   identify missing information;
-   ask useful questions;
-   propose alternatives;
-   challenge assumptions;
-   research external information when appropriate;
-   inspect existing project documentation;
-   find contradictions;
-   identify edge cases;
-   suggest decisions;
-   convert resolved discussions into requirements;
-   maintain traceability;
-   prepare implementation work.

The objective is convergence toward an implementation-ready specification.

* * *

# 3\. Primary Object: Feature Workspace

A feature should be represented as a workspace rather than a single Markdown file.

Example:

```text
Feature: WhatsApp Communication Mirroring

Status: Exploring

Problem
Requirements
Questions
Decisions
Research
References
Assets
Related Documentation
Implementation
```

The workspace groups all information related to the feature while allowing the underlying information to remain stored as Markdown.

* * *

# 4\. Main UI

The primary workspace should use a three-area layout.

```text
┌──────────────────────────────────────────────────────────────────┐
│ Feature: WhatsApp Mirroring                         Exploring    │
├──────────────────┬─────────────────────────┬─────────────────────┤
│ CONTEXT          │ DOCUMENT                │ AI / DISCUSSION     │
│                  │                         │                     │
│ Overview         │ # WhatsApp Mirroring    │ Questions           │
│ Requirements     │                         │ Suggestions         │
│ Questions        │ ## Problem              │ Research            │
│ Decisions        │ ...                     │ Findings            │
│ Research         │                         │                     │
│ References       │                         │                     │
│ Assets           │                         │                     │
│ Related Docs     │                         │                     │
│ Implementation   │                         │                     │
└──────────────────┴─────────────────────────┴─────────────────────┘
```

The document remains visually central.

AI operates around the document rather than replacing it.

* * *

# 5\. Main Workflow

The feature lifecycle should have four primary stages:

```text
Explore → Review → Resolve → Build
```

These should be visible in the UI.

* * *

# 6\. Explore Mode

Explore mode is used when creating or extending a feature.

Its purpose is to convert an incomplete idea into a structured specification.

A user might begin with:

> I want all communication between clients and Fairies to be mirrored between Viva and WhatsApp.

The system should analyze the request and determine what information is missing.

* * *

# 7\. Guided Discovery

The experience should not behave as an unrestricted chatbot.

The AI should maintain a model of feature completeness.

Example:

```text
Feature Understanding

Problem                 ✓
Target Users            ✓
Primary Workflow        ✓
Permissions             ?
Failure Scenarios       ?
Data Model              ?
Notifications           ✓
Security                ?
Analytics               ?
Dependencies            ?
Acceptance Criteria     ?
```

The AI should prioritize questions based on their impact on the specification.

Example:

```text
You said messages should exist both on Viva and WhatsApp.

There are several possible synchronization models:

A. Viva is the source of truth.
B. WhatsApp is the source of truth.
C. Both systems behave as equal peers.
D. WhatsApp acts only as a transport layer.

Which model should be used?
```

Available actions:

```text
[Choose A]
[Choose B]
[Choose C]
[Choose D]

[Suggest another approach]
[Research this]
[Show pros/cons]
[Skip for now]
```

* * *

# 8\. Contextual AI Actions

AI functionality should be available directly from the document.

When text is selected, the user should receive contextual actions such as:

```text
Ask AI
Challenge
Expand
Research
Find Edge Cases
Find Contradictions
Find Related Documentation
Explain
Generate Diagram
Turn Into Requirement
Create Decision
Create Question
```

This allows interaction to originate from documentation rather than requiring the user to move everything into a chat.

* * *

# 9\. Information Ingestion

The workspace should accept multiple information sources.

Examples:

-   Markdown;
-   text;
-   PDFs;
-   screenshots;
-   diagrams;
-   UI mockups;
-   images;
-   API documentation;
-   GitHub issues;
-   URLs;
-   code;
-   conversations;
-   meeting notes;
-   voice notes;
-   existing requirements.

The system should determine the likely role of each source.

Example:

```text
Screenshot
→ UI Reference

URL
→ External Research

GitHub Issue
→ Previous Implementation

Markdown
→ Related Specification

Conversation
→ Stakeholder Input

Diagram
→ Architecture Reference
```

* * *

# 10\. Extracted Knowledge

Ingested information should not automatically become requirements.

The AI should extract candidate facts and present them for confirmation.

Example:

```text
7 relevant facts were extracted.

✓ WhatsApp messages must appear inside Viva.
✓ Messages sent from Viva must reach WhatsApp.
? WhatsApp appears to be optional for a conversation.
? Viva may need to remain the system of record.

[Accept]
[Reject]
[Edit]
[Discuss]
```

This creates an explicit boundary between source material and accepted project knowledge.

* * *

# 11\. Research

The AI should be able to research missing information.

Research may include:

-   Internet search;
-   project documentation;
-   repository/code search;
-   GitHub issues;
-   architecture documents;
-   API documentation;
-   previously implemented features.

Research results should preserve their sources.

The system should distinguish:

```text
Project Fact
External Fact
AI Inference
User Decision
Open Assumption
```

These should never silently become interchangeable.

* * *

# 12\. Review Mode

Review mode is used when documentation already exists.

Its objective is to determine whether the specification is complete, consistent, understandable, and implementation-ready.

Example review dashboard:

```text
Review

Completeness        7 findings
Ambiguities         4
Contradictions      2
Edge Cases          11
Architecture        3
Security            2
UX                  6
Operations          4
Open Questions      8
Related Docs        5
External Research   3
```

* * *

# 13\. Review Perspectives

The review engine may internally use specialized perspectives such as:

-   Product;
-   UX;
-   Architecture;
-   Backend;
-   Frontend;
-   Security;
-   QA;
-   Reliability;
-   Operations;
-   Data;
-   Privacy;
-   Business.

The UI should normally present unified findings rather than exposing many independent AI agents.

Example:

```text
BLOCKING

REQ-12 does not define authorization behavior.

Security · Backend
```

or:

```text
HIGH

No behavior is defined for duplicate WhatsApp webhooks.

Backend · Reliability
```

* * *

# 14\. Findings

Every review finding should be attached to relevant documentation whenever possible.

Example:

```text
AMBIGUOUS REQUIREMENT

"Messages should immediately appear on both platforms."

What does "immediately" mean?

Possible interpretations:

• < 1 second
• < 5 seconds
• eventual consistency
• unspecified

Severity:
Requirement Blocker

[Resolve]
[Discuss]
[Edit Requirement]
[Dismiss]
```

A finding should have a lifecycle.

Possible statuses:

```text
Open
Discussing
Resolved
Accepted Risk
Dismissed
```

* * *

# 15\. Questions as First-Class Objects

Questions should not exist only as conversational text.

They should be explicit objects.

Example:

```text
Q-032

What happens when WhatsApp delivery succeeds
but database persistence fails?

Status: Open

Blocking:
REQ-014

Owner:
Boris
```

Possible question types:

```text
Product
Technical
Architecture
UX
Security
Business
Research
Clarification
```

Questions can block requirements or feature readiness.

* * *

# 16\. Decisions as First-Class Objects

Important conclusions should become explicit decisions.

Example:

```text
DEC-018

Title:
Viva remains the source of truth for messages.

Status:
Accepted

Context:
Messages exist on Viva and WhatsApp.

Alternatives:

1. WhatsApp as source of truth.
2. Viva as source of truth.
3. Dual-master synchronization.

Decision:
Viva remains the source of truth.

Reason:
...

Consequences:
...
```

The AI should detect when a discussion appears to have reached a decision.

Example:

```text
This discussion appears to contain an architectural decision.

Save as Decision?

[Create Decision]
[Continue Discussion]
```

Decisions may function similarly to ADRs but should support product and business decisions in addition to architecture decisions.

* * *

# 17\. Resolve Mode

Resolve mode focuses on outstanding uncertainty.

The system should aggregate:

-   open questions;
-   contradictions;
-   ambiguities;
-   unresolved findings;
-   assumptions;
-   missing decisions;
-   research gaps.

Example:

```text
RESOLUTION CENTER

2 Blocking Questions
3 Conflicting Requirements
4 Important Findings
1 Research Gap
```

Example interaction:

```text
Conflict detected.

REQ-12:
Every WhatsApp message must be stored.

REQ-19:
Users may permanently delete WhatsApp messages.

How should deletion work?

[Delete Everywhere]
[Keep Audit Record]
[Research Compliance]
[Propose Alternatives]
[Discuss]
```

The goal of Resolve mode is to move the specification toward convergence.

* * *

# 18\. Feature Readiness

The workspace should show specification readiness.

Example:

```text
Feature Readiness

Requirements          23
Decisions              8
Open Questions         4
Blocking Questions     2
Unresolved Findings    3
Research Gaps          1

████████████████░░░░ 82%
```

The readiness percentage should not be an arbitrary AI confidence score.

It should be calculated from explicit measurable conditions.

Examples:

-   blocking questions resolved;
-   requirements reviewed;
-   acceptance criteria defined;
-   dependencies identified;
-   contradictions resolved;
-   required decisions accepted;
-   implementation coverage complete.

* * *

# 19\. Requirements

Requirements should become structured objects rather than ordinary bullet points.

Example:

```text
REQ-014

When a client sends a WhatsApp message,
Viva must persist the message before making
it visible to the Fairy.

Status:
Approved

Acceptance Criteria:

✓ Message is persisted exactly once.
✓ Message appears in the Viva conversation.
✓ Sender identity is resolved.
✓ Original timestamp is preserved.

Dependencies:

REQ-009
DEC-018

Sources:

Q-032
DEC-018

Implementation:
Not Created
```

* * *

# 20\. Requirement Types

Possible requirement types include:

```text
Functional
Non-Functional
UX
Security
Performance
Reliability
Privacy
Analytics
Operational
Compliance
```

Requirements should support dependencies between each other.

* * *

# 21\. Traceability

Traceability should be a fundamental DDE capability.

The user should be able to navigate:

```text
Original Idea
     ↓
Source Material
     ↓
Research
     ↓
Question
     ↓
Decision
     ↓
Requirement
     ↓
GitHub Issue
     ↓
Pull Request
     ↓
Code
```

This allows the user to answer questions such as:

-   Why does this requirement exist?
-   Who decided this?
-   What research supported the decision?
-   Which issue implements the requirement?
-   Which code implements it?
-   What requirements are affected if this decision changes?

* * *

# 22\. Knowledge Graph

The semantic model naturally forms a project knowledge graph.

Example:

```text
Feature
  │
  ├── contains → Requirement
  │
  ├── contains → Question
  │
  ├── contains → Decision
  │
  ├── references → Research
  │
  ├── references → Document
  │
  └── implemented-by → GitHub Issue

Question
  └── resolved-by → Decision

Decision
  └── produces → Requirement

Requirement
  ├── depends-on → Requirement
  └── implemented-by → Issue

Issue
  └── implemented-by → Pull Request
```

The graph does not necessarily need to be shown visually by default.

It should primarily power navigation, impact analysis, AI context selection, and traceability.

* * *

# 23\. Markdown Semantic Layer

Structured objects should remain representable in Markdown.

Example:

```yaml
---
type: requirement
id: REQ-014
status: approved
feature: whatsapp-mirroring

depends_on:
  - REQ-009

decisions:
  - DEC-018

sources:
  - Q-032
---
```

The DDE can maintain additional indexes for performance, but Markdown remains portable and understandable outside the application.

* * *

# 24\. Build Mode

Build mode converts approved requirements into implementation work.

It should not immediately generate code.

The first step is implementation decomposition.

Example:

```text
EPIC
WhatsApp Communication Mirroring

├── Issue 1
│   WhatsApp webhook ingestion
│
│   REQ-01
│   REQ-02
│   REQ-07
│
├── Issue 2
│   Conversation synchronization
│
│   REQ-03
│   REQ-04
│   REQ-08
│
├── Issue 3
│   Delivery status
│
│   REQ-09
│   REQ-10
│
└── Issue 4
    Failure recovery

    REQ-11
    REQ-12
    REQ-13
```

The AI proposes decomposition.

The user remains responsible for approving and modifying it.

* * *

# 25\. Requirement Coverage

Before GitHub issues are created, the system should verify requirement coverage.

Example:

```text
Implementation Coverage

27 / 29 requirements covered

Missing:

REQ-018
REQ-023
```

Users should be able to drag requirements between proposed implementation issues.

* * *

# 26\. GitHub Integration

After approval, implementation items can become GitHub issues.

Each issue should preserve references to its originating requirements.

Example:

```text
GitHub Issue #481

Implement inbound WhatsApp webhook handling.

Requirements:

REQ-001
REQ-002
REQ-007

Decisions:

DEC-018
```

The DDE should later be able to associate:

```text
Requirement
    ↓
GitHub Issue
    ↓
Pull Request
    ↓
Implementation
```

* * *

# 27\. Change Impact Analysis

Because relationships are explicitly tracked, the DDE should eventually support impact analysis.

Example:

```text
DEC-018 changed.

Potential impact:

Requirements:
REQ-014
REQ-017
REQ-021

GitHub Issues:
#481
#489

Documents:
architecture/messaging.md

Potentially affected code:
services/messaging/*
```

The user can then initiate a targeted review.

* * *

# 28\. Proposed Feature Statuses

A feature could move through:

```text
Idea
Exploring
Draft
Review
Resolving
Ready
Implementing
Implemented
Verified
Archived
```

Transitions should not necessarily be rigid.

The status primarily communicates maturity.

* * *

# 29\. Main Navigation

The primary feature navigation could contain:

```text
Overview

Explore
Review
Resolve

Requirements
Questions
Decisions
Research

Implementation
References
History
```

The top-level actions remain:

```text
EXPLORE → REVIEW → RESOLVE → BUILD
```

* * *

# 30\. History and Provenance

Every important object should maintain provenance.

Examples:

```text
Created manually
Generated from discussion
Extracted from PDF
Derived from DEC-018
Generated by AI
Imported from GitHub
```

Important modifications should also be visible through Git history or application-level history.

* * *

# 31\. AI Context Selection

The AI should not blindly receive the entire project.

The DDE should construct relevant context based on the current operation.

For example, reviewing `REQ-014` may automatically retrieve:

```text
Current Feature
Relevant Decisions
Dependencies
Related Requirements
Architecture Documentation
Related GitHub Issues
Relevant Source Code
External Research
```

The knowledge graph should help determine the context.

* * *

# 32\. AI Actions Architecture

AI operations should be modeled as explicit actions rather than only free-form chat.

Examples:

```text
Explore Feature
Ask Clarifying Question
Research Topic
Review Document
Challenge Assumption
Find Contradictions
Find Edge Cases
Find Related Information
Create Question
Create Decision
Generate Requirement
Review Requirement
Generate Acceptance Criteria
Analyze Impact
Generate Implementation Plan
Create GitHub Issues
```

Free-form chat should still exist, but structured actions provide predictable workflows.

* * *

# 33\. MVP Scope

The first version should focus on the core workflow.

## Phase 1

Implement:

-   Feature Workspace;
-   Markdown-based storage;
-   Explore mode;
-   AI guided discovery;
-   contextual AI actions;
-   Questions;
-   Decisions;
-   Requirements;
-   basic Review mode.

The target workflow becomes:

```text
Idea
→ Explore
→ Questions
→ Decisions
→ Requirements
```

* * *

## Phase 2

Add:

-   multimodal ingestion;
-   external research;
-   project-wide document search;
-   advanced review;
-   contradiction detection;
-   edge-case analysis;
-   Resolve Center;
-   readiness evaluation.

Workflow:

```text
Idea
→ Explore
→ Research
→
```