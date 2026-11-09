---
type: bug
id: BUG-063
title: "Prototype from code of a Tailwind app is unstyled: the source CSS needs a Tailwind build that the prototype never runs"
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
updated: 2026-11-04
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

## Cause

- The stylesheet of a prototype from the code of a Tailwind v4 app is the application's own source: it starts with `@import "tailwindcss"` and holds `@theme`, `@utility` and `@layer` rules, which a browser does not process. The screens and components keep the source's utility classes (377 distinct ones), so none of them had a rule and the prototype opened as raw HTML.
- MarkView had no Tailwind handling at all: nothing compiled the source and nothing carried a browser build. The coverage note ("globals.css refers to 1 file that could not be found in the project (tailwindcss)") already pointed at it but was read as harmless.

## Verification

`prototype-tailwind-tests.sh` (logic, the style's JavaScriptCore round trip with quotes, backslashes and U+2028, idempotence, repair of a missing line, the baseline unchanged; it fails without the baseline subtraction and without page linking), `prototype-tailwind-render-tests.sh` (WKWebView through the preview's scheme handler: no rule before, the theme's rules after, including a class the page adds later), every other prototype suite, the Debug build with the vendored file in the bundle, and the three pull request checks. On a scratchpad copy of the vivaa prototype `ensure` linked 118 pages and headless Chrome renders the gallery and a component page like the real app. The signed DMG of 5.13.2 is notarized (`spctl`: Notarized Developer ID; stapler validates) and published as release v5.13.2 with the vendored file in its bundle.

Not covered: a click-through in the real preview window and of the open-time migration; the header written by the assistant (a collapsed `<details>` menu) still looks plain; Tailwind v3 (`tailwind.config.js`) is not covered; a site that stops importing Tailwind keeps its old `markview/tailwind*.js`.

## Resolution

Fixed in 5.13.2 (pull request #282, together with BUG-064; release v5.13.2). Boris chose to embed the Tailwind v4 browser build instead of a build step or an unstyled preview.

- Vendored `@tailwindcss/browser` 4.3.3 (exact pin in `tools/web-vendor`, copied by `build.sh` to `Resources/Editor/vendor/js/tailwind-browser.js`, row in `vendor/MANIFEST.txt`; nothing loads from a CDN). 4.3.4 was a day old, so the pin is 4.3.3.
- New `PrototypeTailwind` finds the Tailwind entry among the copied originals and writes `markview/tailwind-source.js` (the entry as a `text/tailwindcss` style, without `@source`, `@plugin`, `@config` and local imports) and `markview/tailwind.js`, and links both before `styles.css` from `index.html` and every page under `components/`. The files live in the owned folder, which the assistants neither read nor write.
- Every accepted version ensures it (build, sync, revision, restore). Opening an existing prototype that lacks it saves a version of its own, with no assistant run. The sync baseline hashes pages without the two lines, so adding Tailwind is never taken for an edit.
- A site with no Tailwind entry is left untouched.
