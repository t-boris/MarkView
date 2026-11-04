---
type: bug
id: BUG-069
title: UI Studio finds no source file for Next.js 16 elements
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
ready_to_fix: true
updated: 2026-11-04
---

# UI Studio finds no source file for Next.js 16 elements

## Summary

For a Next.js 16 app (React 19, Turbopack) a selected element shows "Source: none" and "The framework named a source file outside the project", although its component is known. The assistant then has no file to start from.

## Steps to reproduce

1. Open UI Studio on vivaa-platform apps/client-web-app (a monorepo app on Next.js 16 with Turbopack).
2. Select the "Can't find the right package?" card.

## Expected

The element maps to apps/client-web-app/components/... (the PlanningInvitation component's file), exactly or as a clearly marked candidate.

## Actual

Source: none — no development metadata links this element to a source file. Component: PlanningInvitation. "The framework named a source file outside the project."

## Environment

MarkView 5.15.2. React 19 has no _debugSource; the runtime takes the first frame of _debugStack, which under Turbopack is a compiled chunk (/_next/static/chunks/...js). projectPath rejects it and StudioSourceResolution.resolve returns no mapping without falling back to the component-name search.
