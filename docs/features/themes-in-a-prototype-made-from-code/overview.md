---
type: feature
id: themes-in-a-prototype-made-from-code
title: Themes in a prototype made from code
status: ready
owner: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView from Boris's question about broker-fabric themes in the Prototype Studio discussion, 2026-11-03
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: n/a
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
---

# Themes in a prototype made from code

## Idea

Problem: an application with themes (StrikeDesk has dark, midnight, terminal and tastytrade, tastytrade by default) changes much of its look with the theme, but a prototype reconstructed from its code has one fixed look and no way to choose a theme. The stylesheets of all themes are already copied into the prototype; nothing applies a theme (no data-theme attribute is set) and the Appearance settings screen was built as a stub. Who: a reviewer who judges and changes the interface in Prototype Studio. Scope IN: find the theme mechanism of the original (attribute selectors such as [data-theme="x"] in the copied stylesheets, and the default theme), apply the default theme as the application does, offer a theme picker in Prototype Studio that is independent of the generated screens, remember the chosen theme with the prototype. OUT: reproducing the application's Appearance settings screen beyond what the build does today; fonts, zoom and density preferences of the original; themes that need the application's own code to compute colors.

## Problem

## Scope
