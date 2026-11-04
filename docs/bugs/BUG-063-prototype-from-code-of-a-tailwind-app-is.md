---
type: bug
id: BUG-063
title: "Prototype from code of a Tailwind app is unstyled: the source CSS needs a Tailwind build that the prototype never runs"
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# Prototype from code of a Tailwind app is unstyled: the source CSS needs a Tailwind build that the prototype never runs

## Summary

A prototype built from the code of a Tailwind v4 app (vivaa-platform, apps/client-web-app, MarkView 5.12.1) opens as raw HTML: serif text, blue links, no layout. The screens and components keep the source's utility classes (377 distinct ones such as mt-sp10, rounded-lg, border-dashed), but the stylesheets the prototype loads are the source files themselves: globals.css starts with `@import "tailwindcss"` and `@theme`, which a browser does not process, and three of the links point to apps/... paths that do not exist in site/ (only original/apps/... exists). Nothing in MarkView compiles Tailwind, so no utility class has a rule. The coverage note of the build already says "globals.css refers to 1 file that could not be found in the project (tailwindcss)". Verified outside MarkView: the same site in headless Chrome gives the screenshot from the report; a scratchpad copy with Tailwind's own browser build (@tailwindcss/browser 4.3.4, one local 287 KB script, no CDN) and the contents of globals.css in an inline style of type text/tailwindcss renders the real design (hero, search, chips).

## Steps to reproduce

1. Open the vivaa-platform project and build a prototype from code of apps/client-web-app (or open docs/prototypes/client-web-app, v3).
2. Open the preview: the gallery is plain HTML without styling.
3. Reproduce outside MarkView: open docs/prototypes/client-web-app/site/index.html in a browser.

## Expected

A prototype from the code of a Tailwind app looks like the app: its utility classes have rules, offline, with nothing loaded from a CDN.

## Actual

Every utility class is without a rule, so the whole prototype is unstyled; the reviewer cannot judge the design and the preview check reads the result as broken.

## Environment

MarkView 5.12.1 installed (5.13.1 released, not installed); source main 57cdeff. Project: vivaa-platform, docs/prototypes/client-web-app. Related: BUG-062, BUG-064.
